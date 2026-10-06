import XCTest
import Darwin
@testable import WLCore

private actor LocalProbe {
    private var active = 0
    private var maximum = 0
    private var sources: [String] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    let gated: Bool
    init(gated: Bool = false) { self.gated = gated }
    func translate(_ text: String) async -> String {
        active += 1; maximum = max(maximum, active); sources.append(text)
        if gated { await withCheckedContinuation { gates.append($0) } }
        active -= 1; return "本机：\(text)"
    }
    func release() { let pending = gates; gates = []; for gate in pending { gate.resume() } }
    func snapshot() -> (maximum: Int, sources: [String]) { (maximum, sources) }
}
private actor LateDeltaProbe {
    var callback: (@Sendable (String) async -> Void)?
    func set(_ callback: @escaping @Sendable (String) async -> Void) { self.callback = callback }
    func send() async { await callback?("迟到的片段") }
}

final class HybridTranslationTests: XCTestCase {
    private func fixture() async throws -> (URL, SessionStore, LectureSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(root: root); let session = LectureSession(course: "ECON hybrid")
        try await store.save(session); return (root, store, session)
    }
    private func segment(_ index: Int = 0) -> TranscriptSegment {
        var value = TranscriptSegment(start: Double(index * 4), end: Double(index * 4 + 4), english: "The cost is \(index) percent.")
        value.revision = 1; value.localEnabled = true; value.queuedAt = Date(); return value
    }
    private func partial(_ text: String, start: Double = 0, end: Double = 1) -> SpeechPiece {
        SpeechPiece(text: text, start: start, end: end)
    }
    private func request(session: UUID, id: UUID = UUID(), epoch: UUID = UUID(), revision: Int = 1, text: String) -> DraftTranslationRequest {
        DraftTranslationRequest(sessionID: session, captionID: id, epoch: epoch, revision: revision,
                                english: text, start: 0, end: 1, partialFirstAt: Date())
    }
    func testDraftRevisionsReplaceRatherThanAppendAndAcceptOnlyStillValidPrefix() throws {
        var drafts = CaptionDraftCoordinator(); let buffer = SentenceBuffer(); let classroom = UUID()
        drafts.replacePartial(partial("social cost")); drafts.refresh(buffer: buffer, finalizedEnd: -1)
        let first = try XCTUnwrap(drafts.request(session: classroom))
        drafts.replacePartial(partial("social cost is greater")); drafts.refresh(buffer: buffer, finalizedEnd: -1)
        let second = try XCTUnwrap(drafts.request(session: classroom))
        XCTAssertEqual(first.captionID, second.captionID); XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(drafts.current?.english, "social cost is greater")
        XCTAssertEqual(drafts.accept(first, text: "社会成本", at: Date()), .prefix)
        XCTAssertEqual(drafts.accept(second, text: "社会成本更高", at: Date()), .exact)
        XCTAssertEqual(drafts.accept(first, text: "旧中文", at: Date()), .stale)
        XCTAssertEqual(drafts.current?.chinese, "社会成本更高")
        XCTAssertNil(drafts.request(session: classroom))
    }
    func testNegationCorrectionsAndRevertedCorrectionsRejectOldResponsesButRetainShownChinese() throws {
        var drafts = CaptionDraftCoordinator(); let buffer = SentenceBuffer(); let classroom = UUID()
        drafts.replacePartial(partial("cost increases")); drafts.refresh(buffer: buffer, finalizedEnd: -1)
        let old = try XCTUnwrap(drafts.request(session: classroom))
        XCTAssertEqual(drafts.accept(old, text: "成本增加", at: Date()), .exact)
        drafts.replacePartial(partial("cost does not increase")); drafts.refresh(buffer: buffer, finalizedEnd: -1)
        XCTAssertEqual(drafts.current?.chinese, "成本增加")
        XCTAssertEqual(drafts.accept(old, text: "迟到的错误", at: Date()), .stale)
        drafts.replacePartial(partial("cost increases again")); drafts.refresh(buffer: buffer, finalizedEnd: -1)
        XCTAssertEqual(drafts.accept(old, text: "旧前缀", at: Date()), .stale)
        XCTAssertFalse(CaptionSource.isPrefix("cost", of: "costly"))
        XCTAssertFalse(CaptionSource.isPrefix("12", of: "120 percent"))
    }
    func testEmptyPartialRestartAndOverlappingFinalRevokeVolatileText() throws {
        var drafts = CaptionDraftCoordinator(); var buffer = SentenceBuffer(); let classroom = UUID()
        drafts.replacePartial(partial("the unknown tail", end: 3)); drafts.refresh(buffer: buffer, finalizedEnd: -1)
        let old = try XCTUnwrap(drafts.request(session: classroom))
        drafts.replacePartial(partial("")); drafts.refresh(buffer: buffer, finalizedEnd: -1)
        XCTAssertNil(drafts.current); XCTAssertEqual(drafts.accept(old, text: "撤销内容", at: Date()), .stale)
        drafts.replacePartial(partial("the unknown tail", end: 3)); drafts.refresh(buffer: buffer, finalizedEnd: -1)
        XCTAssertEqual(drafts.accept(old, text: "同样文字，旧请求", at: Date()), .stale)
        let final = partial("the finalized words", end: 2)
        drafts.acceptedFinal(final); XCTAssertNil(buffer.append(final)); drafts.refresh(buffer: buffer, finalizedEnd: 2)
        XCTAssertEqual(drafts.current?.english, "the finalized words")
        let fresh = try XCTUnwrap(drafts.request(session: classroom)); drafts.invalidate()
        XCTAssertEqual(drafts.accept(fresh, text: "重启前结果", at: Date()), .stale)
    }
    func testQuietFlushKeepsStableIDAndMovesNonoverlappingTailToNewID() throws {
        var drafts = CaptionDraftCoordinator(); var buffer = SentenceBuffer(); let classroom = UUID()
        let final = partial("stable words", end: 1); XCTAssertNil(buffer.append(final))
        drafts.replacePartial(partial("unfinalized tail", start: 1, end: 2)); drafts.refresh(buffer: buffer, finalizedEnd: 1)
        let oldID = try XCTUnwrap(drafts.current?.id)
        let full = try XCTUnwrap(drafts.request(session: classroom))
        _ = drafts.accept(full, text: "包含尾部", at: Date())
        let frozen = drafts.freeze(try XCTUnwrap(buffer.flush()))
        XCTAssertEqual(frozen.id, oldID); XCTAssertNil(frozen.validLocalChinese)
        drafts.refresh(buffer: buffer, finalizedEnd: 1)
        XCTAssertNotEqual(drafts.current?.id, oldID); XCTAssertEqual(drafts.current?.english, "unfinalized tail")
        XCTAssertEqual(drafts.accept(full, text: "旧尾部", at: Date()), .stale)
    }
    func testFreezeReusesOnlyExactFullSourceNotAnEarlierPrefix() throws {
        var drafts = CaptionDraftCoordinator(); var buffer = SentenceBuffer(); let classroom = UUID()
        drafts.replacePartial(partial("the cost")); drafts.refresh(buffer: buffer, finalizedEnd: -1)
        let prefix = try XCTUnwrap(drafts.request(session: classroom)); _ = drafts.accept(prefix, text: "成本", at: Date())
        let final = partial("the cost is 12 percent.", end: 2)
        drafts.acceptedFinal(final)
        let stable = drafts.freeze(try XCTUnwrap(buffer.append(final)))
        XCTAssertNil(stable.validLocalChinese); XCTAssertNil(stable.exportChinese)
        XCTAssertNotNil(stable.localDisplayedAt)
        var exactDrafts = CaptionDraftCoordinator(); var exactBuffer = SentenceBuffer()
        exactDrafts.replacePartial(final); exactDrafts.refresh(buffer: exactBuffer, finalizedEnd: -1)
        let exact = try XCTUnwrap(exactDrafts.request(session: classroom)); _ = exactDrafts.accept(exact, text: "成本为12%。", at: Date())
        let reused = exactDrafts.freeze(try XCTUnwrap(exactBuffer.append(final)))
        XCTAssertEqual(reused.validLocalChinese, "成本为12%。")
        XCTAssertEqual(reused.id, exact.captionID); XCTAssertEqual(reused.localRevision, reused.sourceRevision)
    }
    func testConcurrentFieldMergesPreserveBothTranslatorsInEitherCompletionOrder() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for gptFirst in [false, true] {
            let source = segment(gptFirst ? 1 : 0); try await store.append(source, session: classroom.id)
            let localID = UUID(), gptID = UUID()
            let local = try await store.beginLocal(source, session: classroom.id, request: localID)
            let gpt = try await store.beginGPT(source, session: classroom.id, request: gptID, at: Date())
            XCTAssertNotNil(local); XCTAssertNotNil(gpt)
            if gptFirst {
                _ = try await store.applyGPT(source, session: classroom.id, request: gptID, status: .completed, chinese: "最终", completedAt: Date())
            }
            _ = try await store.applyLocal(source, session: classroom.id, request: localID, chinese: "本机", at: Date())
            if !gptFirst {
                _ = try await store.applyGPT(source, session: classroom.id, request: gptID, status: .completed, chinese: "最终", completedAt: Date())
            }
            let result = try await store.translationSnapshot(source, session: classroom.id)
            XCTAssertEqual(result?.localChinese, "本机"); XCTAssertEqual(result?.chinese, "最终")
            XCTAssertEqual(result?.displayChinese, "最终"); XCTAssertEqual(result?.exportChinese, "最终")
            let duplicate = try await store.applyGPT(source, session: classroom.id, request: gptID, status: .completed, chinese: "重复覆盖")
            XCTAssertNil(duplicate)
        }
    }
    func testStaleRevisionTokenAndWrongClassroomNeverWriteToJournal() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = segment(); try await store.append(old, session: classroom.id)
        let oldLocal = UUID(), oldGPT = UUID()
        _ = try await store.beginLocal(old, session: classroom.id, request: oldLocal)
        _ = try await store.beginGPT(old, session: classroom.id, request: oldGPT, at: Date())
        var revised = old; revised.revision = 2; revised.english = "Cost does not increase."
        try await store.append(revised, session: classroom.id)
        let local = try await store.applyLocal(old, session: classroom.id, request: oldLocal, chinese: "旧本机", at: Date())
        let gpt = try await store.applyGPT(old, session: classroom.id, request: oldGPT, status: .completed, chinese: "旧GPT")
        XCTAssertNil(local); XCTAssertNil(gpt)
        let newID = UUID(); _ = try await store.beginGPT(revised, session: classroom.id, request: newID, at: Date())
        let badToken = try await store.applyGPT(revised, session: classroom.id, request: oldGPT, status: .completed, chinese: "串台")
        let wrongSession = try await store.applyGPT(revised, session: UUID(), request: newID, status: .completed, chinese: "旧课堂")
        XCTAssertNil(badToken); XCTAssertNil(wrongSession)
        let result = try await store.segments(classroom.id)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].english, revised.english); XCTAssertNil(result[0].chinese)
    }
    func testCancelFailureAndRetryKeepFullLocalFallback() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = segment(); try await store.append(source, session: classroom.id)
        let local = UUID(); _ = try await store.beginLocal(source, session: classroom.id, request: local)
        _ = try await store.applyLocal(source, session: classroom.id, request: local, chinese: "保留中文", at: Date())
        let failed = UUID(); _ = try await store.beginGPT(source, session: classroom.id, request: failed, at: Date())
        _ = try await store.applyGPT(source, session: classroom.id, request: failed, status: .failed, error: "HTTP 401")
        try await store.requeueGPT(classroom.id, includeMock: true)
        let retry = UUID(); _ = try await store.beginGPT(source, session: classroom.id, request: retry, at: Date())
        _ = try await store.cancelGPT(source, session: classroom.id, request: retry)
        let result = try await store.translationSnapshot(source, session: classroom.id)
        XCTAssertEqual(result?.validLocalChinese, "保留中文"); XCTAssertEqual(result?.phase, .localOnly)
        XCTAssertNil(result?.chinese)
        let file = try await store.export(classroom.id, language: .chinese, markdown: false)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("[本机翻译 / GPT 未完成] 保留中文"))
    }
    func testExportPriorityMissingAndOldJSONCompatibility() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var final = segment(); final.chinese = "最终12%"; final.status = .completed
        final.localChinese = "本机12%"; final.localSourceText = final.english; final.localRevision = 1
        var invalid = segment(1); invalid.localChinese = "不应导出"; invalid.localSourceText = "The cost"; invalid.localRevision = 1
        var mock = segment(2); mock.status = .mock; mock.chinese = "模拟"
        for value in [final, invalid, mock] { try await store.append(value, session: classroom.id) }
        for markdown in [false, true] {
            let file = try await store.export(classroom.id, language: .bilingual, markdown: markdown)
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.contains("最终12%")); XCTAssertFalse(text.contains("本机12%"))
            XCTAssertFalse(text.contains("不应导出")); XCTAssertTrue(text.contains("中文缺失")); XCTAssertTrue(text.contains("MOCK"))
        }
        let encoder = JSONEncoder(); var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(final)) as? [String: Any])
        for field in ["revision", "localEnabled", "localChinese", "localSourceText", "localRevision", "gptRevision"] { object.removeValue(forKey: field) }
        let old = try JSONDecoder().decode(TranscriptSegment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.sourceRevision, 1); XCTAssertNil(old.localChinese); XCTAssertEqual(old.finalChinese, "最终12%")
    }
    func testRecoveryReleasesInFlightLocalRequestEvenAfterStop() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var stopped = classroom; stopped.state = .stopped; try await store.save(stopped)
        let source = segment(); try await store.append(source, session: classroom.id)
        _ = try await store.beginLocal(source, session: classroom.id, request: UUID())
        _ = try await store.beginGPT(source, session: classroom.id, request: UUID(), at: Date())
        let reopened = SessionStore(root: root); let issues = try await reopened.recover(); XCTAssertTrue(issues.isEmpty)
        let pending = try await reopened.localPending(classroom.id)
        XCTAssertEqual(pending?.id, source.id); XCTAssertNil(pending?.gptRequestID); XCTAssertNil(pending?.localRequestID)
        XCTAssertNil(pending?.submittedAt)
    }
    func testDelayedUISnapshotsCannotUndoFinalOrClearStreamAndLocalDraft() {
        var base = segment(); base.gptRequestID = UUID(); base.submittedAt = Date()
        var stream = base; stream.chinese = "流式"
        XCTAssertEqual(base.mergingDisplay(stream).chinese, "流式")
        var local = base; local.localChinese = "本机"; local.localRevision = 1; local.localSourceText = base.english; local.localCompletedAt = Date()
        var final = base; final.status = .completed; final.chinese = "最终"; final.completedAt = Date()
        let merged = local.mergingDisplay(final)
        XCTAssertEqual(merged.displayChinese, "最终"); XCTAssertEqual(merged.validLocalChinese, "本机")
        XCTAssertEqual(base.mergingDisplay(merged).validLocalChinese, "本机")
        var revised = base; revised.revision = 2; revised.english = "new source"
        XCTAssertEqual(final.mergingDisplay(revised).english, "new source")
    }
    @MainActor func testGPTStreamsOnlyWithoutFullLocalOrPrefixDraftThenReplacesOnce() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var full = segment(); full.localChinese = "本机完整"; full.localSourceText = full.english; full.localRevision = 1
        let prefix = segment(1), noLocal = segment(2)
        for value in [full, prefix, noLocal] { try await store.append(value, session: classroom.id) }
        let worker = TranslationWorker(store: store, config: TranslatorConfiguration(mock: false, model: "injected", key: nil),
            session: classroom, operation: { _, delta in await delta("流式"); return "GPT最终" })
        worker.hasDraft = { $0 == prefix.id }
        let done = expectation(description: "All GPT finals"); done.expectedFulfillmentCount = 3
        var streams: [UUID] = []
        worker.onUpdate = { value in
            if value.status == .pending && value.chinese != nil { streams.append(value.id) }
            if value.status == .completed { done.fulfill() }
        }
        worker.kick(); await fulfillment(of: [done], timeout: 5); await worker.waitForCancellation()
        XCTAssertEqual(streams, [noLocal.id])
        let records = try await store.segments(classroom.id)
        XCTAssertTrue(records.allSatisfy { $0.finalChinese == "GPT最终" }); XCTAssertEqual(records[0].localChinese, "本机完整")
    }
    @MainActor func testGPTCallbackAfterCompletionIsDiscardedWithoutPersistingOrRegressingUI() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = segment(); try await store.append(source, session: classroom.id)
        let probe = LateDeltaProbe()
        let worker = TranslationWorker(store: store, config: TranslatorConfiguration(mock: false, model: "injected", key: nil),
            session: classroom, operation: { _, delta in await probe.set(delta); await delta("开始"); return "最终" })
        let done = expectation(description: "Final received"); var shown = ""
        worker.onUpdate = { value in shown = value.displayChinese ?? shown; if value.status == .completed { done.fulfill() } }
        worker.kick(); await fulfillment(of: [done], timeout: 3)
        await probe.send(); await worker.flushDiagnostics()
        XCTAssertEqual(shown, "最终")
        let records = try await store.segments(classroom.id); XCTAssertEqual(records[0].chinese, "最终")
        var events: [Diagnostic] = []
        try JSONLines.scan(Diagnostic.self, at: store.folder(classroom.id).appendingPathComponent("diagnostics.jsonl")) { events.append($0) }
        XCTAssertEqual(events.filter { $0.event == "gpt_stale_response" }.count, 1)
        await worker.waitForCancellation()
    }
    @MainActor func testCoalescingKeepsOneLatestPartialAndContinuousUpdatesDoNotStarveIt() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = LocalProbe(); let local = LocalTranslationWorker(store: store, session: classroom.id,
            draftDelay: 0.03, draftInterval: 0.06, operation: { await probe.translate($0) })
        let output = expectation(description: "Continuous input still produces drafts"); output.expectedFulfillmentCount = 2; output.assertForOverFulfill = false
        local.onDraft = { _, _, _ in output.fulfill(); return .exact }
        let id = UUID(), epoch = UUID()
        for index in 0..<30 {
            local.offer(request(session: classroom.id, id: id, epoch: epoch, revision: index + 1, text: "prefix \(index)"))
            XCTAssertLessThanOrEqual(local.resourceCounts.pendingDraft, 1); XCTAssertLessThanOrEqual(local.resourceCounts.running, 1)
            try await Task.sleep(for: .milliseconds(5))
        }
        await fulfillment(of: [output], timeout: 3)
        try await Task.sleep(for: .milliseconds(100)); await local.shutdown(); await local.flushDiagnostics()
        let observed = await probe.snapshot(); XCTAssertEqual(observed.maximum, 1)
        XCTAssertGreaterThanOrEqual(observed.sources.count, 2); XCTAssertLessThan(observed.sources.count, 10)
        XCTAssertEqual(observed.sources.last, "prefix 29")
    }
    @MainActor func testBackgroundSuppressesPartialsAndFairQueueDrainsStableSegments() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<8 { try await store.append(segment(index), session: classroom.id) }
        let probe = LocalProbe(); let local = LocalTranslationWorker(store: store, session: classroom.id,
            draftDelay: 0, draftInterval: 0, operation: { await probe.translate($0) })
        let done = expectation(description: "All stable local work drains"); done.expectedFulfillmentCount = 8
        local.onUpdate = { if $0.validLocalChinese != nil { done.fulfill() } }
        local.setForeground(false)
        for _ in 0..<20 { local.offer(request(session: classroom.id, text: "must not translate partial")); local.kick() }
        await fulfillment(of: [done], timeout: 5); await local.shutdown(); await local.flushDiagnostics()
        let observed = await probe.snapshot(); XCTAssertEqual(observed.maximum, 1); XCTAssertEqual(observed.sources.count, 8)
        XCTAssertEqual(observed.sources.first, segment(7).english); XCTAssertEqual(observed.sources[1], segment(0).english)
        XCTAssertEqual(local.resourceCounts.pendingDraft, 0)
    }
    @MainActor func testDeadlineDoesNotReleaseUncooperativeSlotOrAcceptLateDraft() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = LocalProbe(gated: true)
        let local = LocalTranslationWorker(store: store, session: classroom.id, deadlineSeconds: 0.03,
            draftDelay: 0, draftInterval: 0, operation: { await probe.translate($0) })
        let timedOut = expectation(description: "Deadline invalidates without awaiting provider")
        local.onState = { if $0.contains("超时") { timedOut.fulfill() } }
        var late = 0; local.onDraft = { _, _, _ in late += 1; return .exact }
        local.offer(request(session: classroom.id, text: "slow"))
        await fulfillment(of: [timedOut], timeout: 2)
        XCTAssertEqual(local.resourceCounts.running, 1)
        for _ in 0..<20 { local.offer(request(session: classroom.id, text: "new")); local.kick() }
        await local.shutdown(); XCTAssertEqual(local.resourceCounts.running, 1)
        await probe.release(); try await Task.sleep(for: .milliseconds(30)); await local.flushDiagnostics()
        let observed = await probe.snapshot(); XCTAssertEqual(observed.sources, ["slow"]); XCTAssertEqual(late, 0)
        XCTAssertEqual(local.resourceCounts.running, 0)
    }
    @MainActor func testPartialDedupAndOldClassroomRequestAreIgnored() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = LocalProbe(); let local = LocalTranslationWorker(store: store, session: classroom.id,
            draftDelay: 0, draftInterval: 0, operation: { await probe.translate($0) })
        let done = expectation(description: "One result"); local.onDraft = { _, _, _ in done.fulfill(); return .exact }
        let first = request(session: classroom.id, text: "same")
        local.offer(first); await fulfillment(of: [done], timeout: 3)
        for _ in 0..<20 { local.offer(first) }
        local.offer(request(session: UUID(), text: "wrong classroom"))
        try await Task.sleep(for: .milliseconds(30)); await local.shutdown()
        let observed = await probe.snapshot(); XCTAssertEqual(observed.sources, ["same"])
    }
    @MainActor func testModelFailureLeavesEnglishAndGPTQueueIntact() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = segment(); try await store.append(source, session: classroom.id)
        let local = LocalTranslationWorker(store: store, session: classroom.id, operation: { _ in throw WLFailure.message("model missing") })
        let failed = expectation(description: "Local failure"); local.onState = { if $0.contains("model missing") { failed.fulfill() } }
        local.kick(); await fulfillment(of: [failed], timeout: 3); await local.shutdown()
        let pending = try await store.pending(classroom.id); XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending[0].english, source.english)
        XCTAssertNil(pending[0].chinese); XCTAssertEqual(pending[0].localError, "model missing")
    }
    @MainActor func testAcceleratedThreeHourHybridPersistenceRecoveryAndExport() async throws {
        let (root, store, classroom) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let began = Date(), baseline = residentBytes(); var peak = baseline
        var drafts = CaptionDraftCoordinator(); var buffer = SentenceBuffer(); var revisions = 0
        for index in 0..<2700 {
            for revision in 0..<4 {
                drafts.replacePartial(partial("The cost is \(index) percent" + (revision > 0 ? " today" : ""), start: Double(index * 4), end: Double(index * 4 + 3)))
                drafts.refresh(buffer: buffer, finalizedEnd: Double(index * 4)); revisions += 1
            }
            let piece = partial("The cost is \(index) percent today.", start: Double(index * 4), end: Double(index * 4 + 4))
            drafts.acceptedFinal(piece)
            var value = drafts.freeze(try XCTUnwrap(buffer.append(piece))); value.localEnabled = true; value.gptDeferred = true
            try await store.appendFinal(piece, session: classroom.id); try await store.append(value, session: classroom.id)
            drafts.refresh(buffer: buffer, finalizedEnd: piece.end)
        }
        let local = LocalTranslationWorker(store: store, session: classroom.id, operation: { "离线：" + $0 })
        let done = expectation(description: "Three-hour local backlog"); done.expectedFulfillmentCount = 2700
        local.onUpdate = { if $0.validLocalChinese != nil { peak = max(peak, self.residentBytes()); done.fulfill() } }
        local.setForeground(false); await fulfillment(of: [done], timeout: 120)
        await local.shutdown(); await local.flushDiagnostics()
        let reopened = SessionStore(root: root); let issues = try await reopened.recover(); XCTAssertTrue(issues.isEmpty)
        let records = try await reopened.segments(classroom.id)
        XCTAssertEqual(records.count, 2700); XCTAssertEqual(Set(records.map(\.id)).count, 2700)
        XCTAssertTrue(records.allSatisfy { $0.validLocalChinese != nil && $0.chinese == nil })
        let backlog = try await reopened.localPending(classroom.id); XCTAssertNil(backlog)
        for language in ExportLanguage.allCases {
            for markdown in [false, true] {
                let file = try await reopened.export(classroom.id, language: language, markdown: markdown)
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertEqual(text.components(separatedBy: " – ").count - 1, 2700)
                XCTAssertFalse(text.contains("中文缺失")); if language != .english { XCTAssertTrue(text.contains("本机翻译 / GPT 未完成")) }
            }
        }
        peak = max(peak, residentBytes()); let growth = peak > baseline ? peak - baseline : 0
        XCTAssertLessThan(growth, 128 * 1024 * 1024)
        XCTAssertEqual(local.resourceCounts.running, 0); XCTAssertEqual(local.resourceCounts.pendingDraft, 0)
        let metrics: [String: Any] = ["segments": records.count, "partial_updates": revisions, "simulated_seconds": 10800,
            "pending_local_at_end": 0, "active_at_end": local.resourceCounts.running,
            "rss_growth_mb": Double(growth) / 1048576, "wall_seconds": Date().timeIntervalSince(began)]
        print("WL_HYBRID_STRESS_REPORT " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), as: UTF8.self))
    }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        } }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
