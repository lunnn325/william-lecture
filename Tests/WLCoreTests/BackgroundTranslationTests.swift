import XCTest
@testable import WLCore

private actor AvailabilityProbe {
    var available = false
    func install() { available = true }
    func translate(_ text: String) throws -> String {
        guard available else { throw LocalProviderFailure.unavailable }; return "已恢复本机中文"
    }
}

final class BackgroundTranslationTests: XCTestCase {
    private func fixture() async throws -> (URL, SessionStore, LectureSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(root: root), session = LectureSession(course: "Background")
        try await store.save(session); return (root, store, session)
    }
    @MainActor func testForegroundRequeuesIncompleteResponsesAndPublishesFinalOverLocal() async throws {
        let (root, store, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var segment = TranscriptSegment(start: 0, end: 1, english: "The price falls.")
        segment.status = .failed; segment.error = TranslationResponseFailure.incomplete.localizedDescription
        segment.localEnabled = true; segment.localChinese = "本机草稿"; segment.localRevision = 1; segment.localSourceText = segment.english
        try await store.append(segment, session: session.id)
        let worker = TranslationWorker(store: store, config: TranslatorConfiguration(mock: false, model: "test", key: nil), session: session,
            operation: { _, delta in await delta("最终"); return "价格下降。" })
        var states: [String] = []; worker.onState = { states.append($0) }
        let idle = expectation(description: "Missing final is not reported as caught up")
        worker.onState = { state in states.append(state); if state.contains("待补齐") { idle.fulfill() } }
        worker.kick(); await fulfillment(of: [idle], timeout: 2)
        XCTAssertFalse(states.contains("翻译已跟上"))
        let done = expectation(description: "Foreground reconciliation publishes complete GPT result")
        worker.onUpdate = { if $0.finalChinese == "价格下降。" { done.fulfill() } }
        await worker.resumeAfterForeground(); await fulfillment(of: [done], timeout: 2); await worker.waitForCancellation()
        let saved = try await store.segments(session.id)
        XCTAssertEqual(saved.first?.finalChinese, "价格下降。"); XCTAssertEqual(saved.first?.validLocalChinese, "本机草稿")
        await worker.resumeAfterForeground(); await Task.yield()
        XCTAssertEqual(worker.resourceCounts.requests, 0, "Foreground does not undo manual cancellation")
    }
    @MainActor func testForegroundRecoversLocalProviderWithoutResettingInFlightRequests() async throws {
        let (root, store, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var segment = TranscriptSegment(start: 0, end: 1, english: "A complete local source."); segment.localEnabled = true
        try await store.append(segment, session: session.id)
        let probe = AvailabilityProbe(), local = LocalTranslationWorker(store: store, session: session.id, operation: { try await probe.translate($0) })
        let unavailable = expectation(description: "Temporary model failure")
        local.onState = { if $0.contains("模型未准备") { unavailable.fulfill() } }
        local.setForeground(false); local.kick(); await fulfillment(of: [unavailable], timeout: 2)
        await probe.install()
        let done = expectation(description: "Installed session recovers")
        local.onUpdate = { if $0.validLocalChinese == "已恢复本机中文" { done.fulfill() } }
        local.setForeground(true); await local.resumeAfterForeground(); await fulfillment(of: [done], timeout: 2)
        await local.shutdown()
        var second = TranscriptSegment(start: 2, end: 3, english: "Still translating."); second.localEnabled = true
        try await store.append(second, session: session.id)
        let token = UUID(); let begun = try await store.beginLocal(second, session: session.id, request: token)
        try await store.resetLocalFailures(session.id)
        let current = try await store.translationSnapshot(second, session: session.id)
        XCTAssertEqual(current?.localRequestID, token)
        XCTAssertNotNil(begun)
        await local.resumeAfterForeground(); XCTAssertEqual(local.resourceCounts.pendingDraft, 0)
    }
    func testDurableForegroundSnapshotUpdatesOlderReaderRowsWithoutResumingFollow() async throws {
        let (root, store, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var input: [TranscriptSegment] = []
        for index in 0..<90 {
            let segment = TranscriptSegment(start: Double(index), end: Double(index + 1), english: "Sentence \(index).")
            input.append(segment); try await store.append(segment, session: session.id)
        }
        var feed = CaptionFeed(limit: 180); feed.merge(Array(input.prefix(20))); feed.suspend()
        let request = UUID(); let begun = try await store.beginGPT(input[3], session: session.id, request: request, at: Date())
        let completed = try await store.applyGPT(try XCTUnwrap(begun), session: session.id, request: request, status: .completed, chinese: "后台最终译文")
        let rows = try await store.workspaceSnapshot(session.id, retaining: Set(feed.rows.map(\.id)), latest: 30)
        XCTAssertEqual(rows.count, 50); feed.merge(rows)
        XCTAssertEqual(feed.rows.first { $0.id == input[3].id }?.finalChinese, completed?.finalChinese)
        XCTAssertFalse(feed.following); XCTAssertEqual(feed.rows.last?.id, input.last?.id)
        let health = try await store.translationGaps(session.id); XCTAssertEqual(health.gpt, 89)
    }
}
