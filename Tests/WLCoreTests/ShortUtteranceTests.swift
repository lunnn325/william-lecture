import XCTest
@testable import WLCore

private actor FragmentProbe {
    var counts: [String: Int] = [:]
    var calls: [String] = []
    var active = 0
    var peak = 0
    var gate: CheckedContinuation<Void, Never>?
    func first(_ text: String) -> Bool {
        counts[text, default: 0] += 1
        return counts[text] == 1
    }
    func local(_ text: String) async -> String {
        calls.append(text); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if text == "slow" { await withCheckedContinuation { gate = $0 } }
        return "本机：" + text
    }
    func release() { gate?.resume(); gate = nil }
    func snapshot() -> (calls: [String], peak: Int) { (calls, peak) }
}

final class ShortUtteranceTests: XCTestCase {
    private func fixture() async throws -> (URL, SessionStore, LectureSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        return (root, store, session)
    }
    func testOnlyExactStandaloneFragmentsSkipGPT() async throws {
        let (root, store, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for word in ["can", " UH. ", "Okay?", "yeah"] { XCTAssertTrue(ShortUtterance.localOnly(word)) }
        for text in ["Can you explain?", "I can't agree.", "really?", "Okay, the cost is 5.", "No."] {
            XCTAssertFalse(ShortUtterance.localOnly(text))
        }
        XCTAssertNil(ShortUtterance.draft("can"))
        var local = TranscriptSegment(start: 0, end: 1, english: "okay")
        local.localEnabled = true
        let sentence = TranscriptSegment(start: 1, end: 3, english: "Can you explain?")
        let localDisabled = TranscriptSegment(start: 3, end: 4, english: "okay")
        for segment in [local, sentence, localDisabled] { try await store.append(segment, session: session.id) }
        let pending = try await store.pending(session.id)
        XCTAssertEqual(pending.map(\.id), [sentence.id, localDisabled.id])
        let request = UUID()
        let begun = try await store.beginLocal(local, session: session.id, request: request)
        let saved = try await store.applyLocal(try XCTUnwrap(begun), session: session.id, request: request, chinese: "好", at: Date())
        XCTAssertEqual(saved?.phase, .localOnly)
        XCTAssertEqual(saved?.exportChinese, "好")
    }
    @MainActor func testLocalEmptyResponseRetriesOnceAndCommonWordNeedsNoProvider() async throws {
        let (root, store, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var sentence = TranscriptSegment(start: 0, end: 1, english: "What are you doing?")
        sentence.localEnabled = true
        var word = TranscriptSegment(start: 1, end: 2, english: "uh")
        word.localEnabled = true
        let probe = FragmentProbe()
        let local = LocalTranslationWorker(store: store, session: session.id, operation: { text in
            if await probe.first(text) { return "" }
            return "你在做什么？"
        })
        let done = expectation(description: "Both full sentence and local word translated")
        done.expectedFulfillmentCount = 2
        local.onUpdate = { if $0.validLocalChinese != nil { done.fulfill() } }
        try await store.append(sentence, session: session.id)
        try await store.append(word, session: session.id)
        local.kick(); await fulfillment(of: [done], timeout: 3); await local.shutdown()
        let records = try await store.segments(session.id)
        XCTAssertEqual(records.map(\.validLocalChinese), ["你在做什么？", "呃"])
        let counts = await probe.counts
        XCTAssertEqual(counts[sentence.english], 2); XCTAssertNil(counts["uh"])
    }
    @MainActor func testLocalTimeoutResumesAfterUnderlyingTaskEndsWithoutOverlap() async throws {
        let (root, store, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = FragmentProbe()
        let local = LocalTranslationWorker(store: store, session: session.id, deadlineSeconds: 0.1,
            draftDelay: 0, draftInterval: 0, operation: { await probe.local($0) })
        let timeout = expectation(description: "Slow draft times out")
        let recovered = expectation(description: "Latest draft works after old operation exits")
        local.onState = { if $0.contains("超时") { timeout.fulfill() } }
        local.onDraft = { request, _, _ in
            XCTAssertEqual(request.english, "new sentence"); recovered.fulfill(); return .exact
        }
        func request(_ text: String) -> DraftTranslationRequest {
            .init(sessionID: session.id, captionID: UUID(), epoch: UUID(), revision: 1,
                  english: text, start: 0, end: 1, partialFirstAt: Date())
        }
        local.offer(request("slow")); await fulfillment(of: [timeout], timeout: 2)
        XCTAssertEqual(local.resourceCounts.running, 1)
        local.offer(request("new sentence"))
        await probe.release()
        await fulfillment(of: [recovered], timeout: 2); await local.shutdown()
        let result = await probe.snapshot()
        XCTAssertEqual(result.calls, ["slow", "new sentence"]); XCTAssertEqual(result.peak, 1)
    }
    @MainActor func testGPTRetryBackoffReleasesSlotForNextCaption() async throws {
        let (root, store, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = TranscriptSegment(start: 0, end: 1, english: "First sentence.")
        let next = TranscriptSegment(start: 1, end: 2, english: "Next sentence.")
        for source in [first, next] { try await store.append(source, session: session.id) }
        let probe = FragmentProbe()
        let worker = TranslationWorker(store: store, config: .init(mock: false, model: "test-only", key: nil),
            session: session, maxConcurrent: 1, operation: { source, _ in
                if source.id == first.id {
                    if await probe.first(source.english) { throw TranslationResponseFailure.incomplete }
                }
                return "译文"
            })
        let advanced = expectation(description: "Next caption completes during first backoff")
        let retried = expectation(description: "Original caption then finishes")
        worker.onUpdate = { source in
            if source.status == .completed {
                if source.id == next.id { advanced.fulfill() } else { retried.fulfill() }
            }
        }
        worker.kick(); await fulfillment(of: [advanced], timeout: 1.5)
        let records = try await store.segments(session.id)
        XCTAssertNil(records.first?.gptRequestID)
        XCTAssertNotNil(records.first?.error)
        await fulfillment(of: [retried], timeout: 5); await worker.waitForCancellation()
        let final = try await store.segments(session.id)
        XCTAssertEqual(final.first?.attempts, 2)
        XCTAssertEqual(final.map(\.finalChinese), ["译文", "译文"])
    }
}
