import XCTest
@testable import WLCore

private actor ShortResponseAttempts {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

final class DailyUseRegressionTests: XCTestCase {
    private func fixture() async throws -> (URL, SessionStore, LectureSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        return (root, store, session)
    }
    func testShortTextDoneAndCompletedPayloadAreUsableWithoutDelta() throws {
        if case .textDone(let text) = try TranslationEvent.decode(["type": "response.output_text.done", "text": "利昂？"]) {
            XCTAssertEqual(text, "利昂？")
        } else { XCTFail("Short full text must not require a delta event") }
        let response: [String: Any] = ["output": [["type": "message", "content": [["type": "output_text", "text": "你在做什么？"]]]]]
        XCTAssertEqual(TranslationEvent.completedText(["type": "response.completed", "response": response]), "你在做什么？")
        XCTAssertNil(TranslationEvent.completedText(["type": "response.incomplete", "response": response]))
        for type in ["response.incomplete", "response.failed", "response.refusal.done"] {
            XCTAssertThrowsError(try TranslationEvent.decode(["type": type, "response": response]))
        }
    }
    @MainActor func testUnusableShortSentenceDoesNotStopOtherTranslations() async throws {
        let (root, store, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var sources = ["Leon?", "Yes, Mother?", "What are you doing?"].enumerated().map {
            TranscriptSegment(start: Double($0.offset), end: Double($0.offset + 1), english: $0.element)
        }
        for source in sources { try await store.append(source, session: session.id) }
        let worker = TranslationWorker(store: store, config: .init(mock: false, model: "test-only", key: nil), session: session,
            operation: { source, _ in
                if source.english == "Leon?" { throw TranslationResponseFailure.refused }
                return "可用中文"
            })
        let finished = expectation(description: "Two successful sentences and one isolated failure"); finished.expectedFulfillmentCount = 3
        worker.onUpdate = { if $0.status == .completed || $0.status == .failed { finished.fulfill() } }
        worker.kick(); await fulfillment(of: [finished], timeout: 3); await worker.waitForCancellation()
        sources = try await store.segments(session.id)
        XCTAssertEqual(sources.filter { $0.finalChinese != nil }.count, 2)
        XCTAssertEqual(sources.first?.phase, .failed)
        XCTAssertTrue(sources.allSatisfy { $0.gptRequestID == nil })
    }
    @MainActor func testIncompleteShortResponseRetriesAndBecomesFinal() async throws {
        let (root, store, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = TranscriptSegment(start: 0, end: 1, english: "Yes?")
        try await store.append(source, session: session.id)
        let attempts = ShortResponseAttempts()
        let worker = TranslationWorker(store: store, config: .init(mock: false, model: "test-only", key: nil), session: session,
            operation: { _, _ in if await attempts.next() == 1 { throw TranslationResponseFailure.incomplete }; return "是吗？" })
        let done = expectation(description: "Retry completes the short sentence")
        worker.onUpdate = { if $0.status == .completed { done.fulfill() } }
        worker.kick(); await fulfillment(of: [done], timeout: 5); await worker.waitForCancellation()
        let saved = try await store.segments(session.id)
        XCTAssertEqual(saved.first?.finalChinese, "是吗？"); XCTAssertEqual(saved.first?.attempts, 2)
    }
    @MainActor func testEmptyLocalFragmentDoesNotDisableSubsequentSentences() async throws {
        let (root, store, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (index, english) in ["Leon?", "What are you doing?"].enumerated() {
            var source = TranscriptSegment(start: Double(index), end: Double(index + 1), english: english)
            source.localEnabled = true; source.gptDeferred = true; try await store.append(source, session: session.id)
        }
        let worker = LocalTranslationWorker(store: store, session: session.id,
            operation: { $0 == "Leon?" ? "" : "你在做什么？" })
        let done = expectation(description: "Local provider continues after an empty fragment")
        worker.onUpdate = { if $0.validLocalChinese != nil { done.fulfill() } }
        worker.kick(); await fulfillment(of: [done], timeout: 3); await worker.shutdown(); await worker.flushDiagnostics()
        let saved = try await store.segments(session.id)
        XCTAssertNotNil(saved[0].localError); XCTAssertEqual(saved[1].validLocalChinese, "你在做什么？")
    }
    func testActorCommitOrderPreventsPendingCallbackFromRestoringProcessing() async throws {
        let (root, store, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var source = TranscriptSegment(start: 0, end: 1, english: "Yes?"); source.localEnabled = true
        try await store.append(source, session: session.id)
        let localID = UUID(), gptID = UUID()
        let localResult = try await store.beginLocal(source, session: session.id, request: localID)
        let pendingResult = try await store.beginGPT(source, session: session.id, request: gptID, at: Date())
        let failedResult = try await store.applyGPT(source, session: session.id, request: gptID, status: .pending, error: "timeout")
        let local = try XCTUnwrap(localResult), pending = try XCTUnwrap(pendingResult), failed = try XCTUnwrap(failedResult)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(pending.mergingDisplay(failed).phase, .failed)
        XCTAssertEqual(local.mergingDisplay(failed).translationUpdate, failed.translationUpdate)
        let completedLocalResult = try await store.applyLocal(source, session: session.id, request: localID, chinese: "是吗？", at: Date())
        let completedLocal = try XCTUnwrap(completedLocalResult)
        XCTAssertEqual(completedLocal.phase, .localOnly)
        XCTAssertEqual(completedLocal.error, "timeout")
        let saved = try await store.segments(session.id)
        XCTAssertEqual(saved[0].validLocalChinese, "是吗？")
    }
    func testSilenceIsNotAnUnfinishedTailButPartialAndFailureAre() {
        XCTAssertNil(AudioRepairRange.unfinishedTail(finalEnd: 4, audioEnd: 8, partial: nil, failed: false))
        let partial = SpeechPiece(text: "unfinished words", start: 5, end: 6)
        XCTAssertEqual(AudioRepairRange.unfinishedTail(finalEnd: 4, audioEnd: 8, partial: partial, failed: false), .init(start: 4, end: 6))
        XCTAssertEqual(AudioRepairRange.unfinishedTail(finalEnd: 4, audioEnd: 8, partial: nil, failed: true), .init(start: 4, end: 8))
        XCTAssertNil(AudioRepairRange.unfinishedTail(finalEnd: 6, audioEnd: 8, partial: partial, failed: false))
    }
    @MainActor func testServerFailureRecoversWithoutNetworkPathChange() async throws {
        let (root, store, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = TranscriptSegment(start: 0, end: 1, english: "Yes?")
        try await store.append(source, session: session.id)
        let attempts = ShortResponseAttempts()
        let worker = TranslationWorker(store: store, config: .init(mock: false, model: "test-only", key: nil), session: session,
            recoveryDelay: 0.02, operation: { _, _ in
                if await attempts.next() <= 3 { throw APIError(status: 500, retryAfter: 0) }; return "是吗？"
            })
        let done = expectation(description: "The timer resumes a failed server request without an NWPathMonitor change")
        worker.onUpdate = { if $0.status == .completed { done.fulfill() } }
        worker.kick(); await fulfillment(of: [done], timeout: 3); await worker.waitForCancellation()
        let saved = try await store.segments(session.id)
        XCTAssertEqual(saved.first?.attempts, 4); XCTAssertEqual(saved.first?.finalChinese, "是吗？")
    }
    func testLibraryFieldMergeKeepsStoppedLifecycleAndManualTitle() async throws {
        let (root, store, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var ended = initial; ended.state = .stopped; ended.updateRecordingDuration(42)
        ended.title = "Week 6"; try await store.save(ended)
        try await store.saveNote(LectureNote(offset: 10), session: ended.id)
        try await store.updateLibraryFields(initial.id, preview: "Updated summary")
        let history = try await store.sessions()
        XCTAssertEqual(history.first?.state, .stopped); XCTAssertEqual(history.first?.duration, 42)
        XCTAssertEqual(history.first?.title, "Week 6"); XCTAssertEqual(history.first?.markCount, 1)
        XCTAssertEqual(history.first?.preview, "Updated summary")
    }
    func testCompletedTextWithDeferredAudioRepairExportsWarningAndKeepsTranslation() async throws {
        let (root, store, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var source = TranscriptSegment(start: 0, end: 1, english: "Yes?")
        source.status = .completed; source.chinese = "是吗？"; try await store.append(source, session: session.id)
        var content = LessonContent(sessionID: session.id, segments: [source]); content.state = .completed
        content.audioRepairWarning = "Speech model unavailable"
        _ = try await store.saveContent(content)
        let exported = try await store.export(session.id, language: .bilingual, markdown: true)
        let text = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(text.contains("是吗？")); XCTAssertTrue(text.contains("部分音频尚未补转写"))
        let encoded = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(LectureSession.self, from: encoded)
        XCTAssertNil(restored.speechLocale)
    }
}
