import XCTest
@testable import WLCore

private actor TranslationProbe {
    private var active = 0
    private var maximum = 0
    private var starts: [UUID] = []
    private var counts: [UUID: Int] = [:]
    private let delays: [UUID: Int]
    private let error: APIError?
    private let errorsBeforeSuccess: Int
    private let started: XCTestExpectation?
    init(delays: [UUID: Int] = [:], error: APIError? = nil, errorsBeforeSuccess: Int = 0,
         started: XCTestExpectation? = nil) {
        self.delays = delays; self.error = error; self.errorsBeforeSuccess = errorsBeforeSuccess; self.started = started
    }
    func translate(_ segment: TranscriptSegment, delta: @escaping @Sendable (String) async -> Void) async throws -> String {
        active += 1; maximum = max(maximum, active); starts.append(segment.id)
        counts[segment.id, default: 0] += 1
        let attempt = counts[segment.id]!
        defer { active -= 1 }
        started?.fulfill()
        await delta("中文 \(Int(segment.start))")
        try await Task.sleep(for: .milliseconds(delays[segment.id] ?? 20))
        if let error, attempt <= errorsBeforeSuccess { throw error }
        return "中文 \(Int(segment.start))"
    }
    func snapshot() -> (maximum: Int, starts: [UUID], counts: [UUID: Int]) { (maximum, starts, counts) }
}

final class TranslationTests: XCTestCase {
    private let config = TranslatorConfiguration(mock: false, model: "test-only", key: nil)
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func segments(_ count: Int) -> [TranscriptSegment] {
        (0..<count).map { index in
            var segment = TranscriptSegment(start: Double(index), end: Double(index + 1), english: "Sentence \(index).")
            segment.queuedAt = Date(); return segment
        }
    }

    @MainActor func testTwoRequestsKeepNewestMovingAndDrainOldestWithoutDuplicates() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let session = LectureSession(course: "ECON")
        try await store.save(session)
        let input = segments(5)
        for segment in input { try await store.append(segment, session: session.id) }
        let probe = TranslationProbe(delays: [input[0].id: 300])
        let worker = TranslationWorker(store: store, config: config, session: session,
            operation: { segment, delta in try await probe.translate(segment, delta: delta) })
        let done = expectation(description: "All independent requests completed"); done.expectedFulfillmentCount = 5
        var completionOrder: [UUID] = []
        worker.onUpdate = { segment in
            if segment.status == .completed { completionOrder.append(segment.id); done.fulfill() }
        }
        worker.kick()
        await fulfillment(of: [done], timeout: 3)
        await worker.waitForCancellation()
        let observed = await probe.snapshot()
        XCTAssertEqual(observed.maximum, 2)
        XCTAssertEqual(Set(observed.starts.prefix(2)), Set([input[0].id, input[4].id]))
        XCTAssertEqual(observed.starts.count, 5)
        XCTAssertTrue(observed.counts.values.allSatisfy { $0 == 1 })
        XCTAssertLessThan(try XCTUnwrap(completionOrder.firstIndex(of: input[4].id)),
                          try XCTUnwrap(completionOrder.firstIndex(of: input[0].id)))
        let records = try await store.segments(session.id)
        XCTAssertEqual(records.count, 5); XCTAssertTrue(records.allSatisfy { $0.status == .completed })
        var diagnostics: [Diagnostic] = []
        try JSONLines.scan(Diagnostic.self, at: store.folder(session.id).appendingPathComponent("diagnostics.jsonl")) { diagnostics.append($0) }
        XCTAssertEqual(diagnostics.filter { $0.event == "translation_first_result" }.count, 5)
        XCTAssertTrue(diagnostics.filter { $0.event == "translation_request" }.allSatisfy { $0.fields["queue_ms"] != nil && $0.fields["buffer_ms"] != nil })
    }

    @MainActor func testNewDurableWorkAndRepeatedWakeupsDuringRequestsAreNotLost() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let session = LectureSession(course: "Live")
        try await store.save(session); let input = segments(3)
        for segment in input.prefix(2) { try await store.append(segment, session: session.id) }
        let started = expectation(description: "Initial requests started"); started.expectedFulfillmentCount = 2
        started.assertForOverFulfill = false
        let probe = TranslationProbe(delays: [input[0].id: 100, input[1].id: 100], started: started)
        let worker = TranslationWorker(store: store, config: config, session: session,
            operation: { segment, delta in try await probe.translate(segment, delta: delta) })
        let done = expectation(description: "Includes newly appended work"); done.expectedFulfillmentCount = 3
        worker.onUpdate = { if $0.status == .completed { done.fulfill() } }
        worker.kick(); await fulfillment(of: [started], timeout: 2)
        try await store.append(input[2], session: session.id)
        for _ in 0..<10 { worker.kick() }
        await fulfillment(of: [done], timeout: 3); await worker.waitForCancellation()
        let observed = await probe.snapshot()
        XCTAssertEqual(observed.starts.count, 3); XCTAssertLessThanOrEqual(observed.maximum, 2)
        let pending = try await store.pending(session.id); XCTAssertTrue(pending.isEmpty)
    }

    @MainActor func testCancellationLeavesEnglishPendingAndNeverPersistsPartialChinese() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let session = LectureSession(course: "Cancel")
        try await store.save(session); let input = segments(2)
        for segment in input { try await store.append(segment, session: session.id) }
        let probe = TranslationProbe(delays: Dictionary(uniqueKeysWithValues: input.map { ($0.id, 10000) }))
        let worker = TranslationWorker(store: store, config: config, session: session,
            operation: { segment, delta in try await probe.translate(segment, delta: delta) })
        let partial = expectation(description: "Both requests streamed"); partial.expectedFulfillmentCount = 2
        worker.onUpdate = { if $0.chinese != nil { partial.fulfill() } }
        worker.kick(); await fulfillment(of: [partial], timeout: 2)
        await worker.waitForCancellation()
        let reopened = SessionStore(root: root)
        let pending = try await reopened.pending(session.id)
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.chinese == nil && $0.completedAt == nil })
    }

    @MainActor func testAuthErrorSuspendsQueueAndPreservesUntouchedBacklog() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let session = LectureSession(course: "Auth")
        try await store.save(session); let input = segments(5)
        for segment in input { try await store.append(segment, session: session.id) }
        let probe = TranslationProbe(error: APIError(status: 401), errorsBeforeSuccess: 99)
        let worker = TranslationWorker(store: store, config: config, session: session,
            operation: { segment, delta in try await probe.translate(segment, delta: delta) })
        let failed = expectation(description: "Both active requests fail"); failed.expectedFulfillmentCount = 2
        worker.onUpdate = { if $0.status == .failed { failed.fulfill() } }
        worker.kick(); await fulfillment(of: [failed], timeout: 2); await worker.waitForCancellation()
        let observed = await probe.snapshot(); XCTAssertEqual(observed.starts.count, 2)
        let records = try await store.segments(session.id)
        XCTAssertEqual(records.filter { $0.status == .pending }.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.chinese == nil })
    }

    @MainActor func testRateLimitRetryIsBoundedAndDoesNotClaimTheSegmentAgain() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let session = LectureSession(course: "Retry")
        try await store.save(session); let input = segments(1)
        try await store.append(input[0], session: session.id)
        let probe = TranslationProbe(error: APIError(status: 429, retryAfter: 0), errorsBeforeSuccess: 2)
        let worker = TranslationWorker(store: store, config: config, session: session,
            operation: { segment, delta in try await probe.translate(segment, delta: delta) })
        let done = expectation(description: "Third attempt succeeds")
        worker.onUpdate = { if $0.status == .completed { done.fulfill() } }
        worker.kick(); await fulfillment(of: [done], timeout: 3); await worker.waitForCancellation()
        let observed = await probe.snapshot(); XCTAssertEqual(observed.counts[input[0].id], 3)
        XCTAssertEqual(observed.maximum, 1)
        let records = try await store.segments(session.id)
        XCTAssertEqual(records[0].attempts, 3); XCTAssertEqual(records[0].status, .completed)
    }

    func testPendingIndexTracksWritesExcludesInFlightAndRebuildsAfterSwitch() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let one = LectureSession(course: "One"), two = LectureSession(course: "Two")
        try await store.save(one); try await store.save(two)
        var input = segments(3)
        for segment in input { try await store.append(segment, session: one.id) }
        let oldest = try await store.pending(one.id, limit: 1); XCTAssertEqual(oldest.first?.id, input[0].id)
        input[0].status = .completed; try await store.append(input[0], session: one.id)
        input[1].status = .failed; try await store.append(input[1], session: one.id)
        let newest = try await store.pending(one.id, limit: 1, newestFirst: true)
        XCTAssertEqual(newest.first?.id, input[2].id)
        let excluded = try await store.pending(one.id, excluding: [input[2].id]); XCTAssertTrue(excluded.isEmpty)
        let other = try await store.pending(two.id); XCTAssertTrue(other.isEmpty)
        let rebuilt = try await store.pending(one.id, retryFailed: true)
        XCTAssertEqual(Set(rebuilt.map(\.id)), Set([input[1].id, input[2].id]))
        let added = TranscriptSegment(start: 4, end: 5, english: "new")
        try await store.append(added, session: one.id)
        let updated = try await store.pending(one.id, newestFirst: true)
        XCTAssertEqual(updated.first?.id, added.id)
    }

    func testBufferUsesPreciseQuietDeadlineAndBoundsUnpunctuatedAudio() {
        let now = Date(timeIntervalSince1970: 1000)
        var buffer = SentenceBuffer()
        XCTAssertNil(buffer.append(SpeechPiece(text: "the marginal", start: 0, end: 1, receivedAt: now)))
        XCTAssertEqual(buffer.quietDeadline, now.addingTimeInterval(0.35))
        XCTAssertNil(buffer.flushIfQuiet(now: now.addingTimeInterval(0.34)))
        XCTAssertNil(buffer.append(SpeechPiece(text: "social cost", start: 1, end: 2, receivedAt: now.addingTimeInterval(0.2))))
        XCTAssertNil(buffer.flushIfQuiet(now: now.addingTimeInterval(0.4)))
        XCTAssertEqual(buffer.flushIfQuiet(now: now.addingTimeInterval(0.56))?.english, "the marginal social cost")
        XCTAssertNil(buffer.quietDeadline)
        XCTAssertEqual(buffer.append(SpeechPiece(text: "long phrase without punctuation", start: 2, end: 7))?.end, 7)
        XCTAssertNil(buffer.flush())
    }

    func testOlderJournalWithoutQueueTimestampRemainsReadable() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(segments(1)[0])) as? [String: Any])
        object.removeValue(forKey: "queuedAt")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let old = try decoder.decode(TranscriptSegment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.queuedAt); XCTAssertEqual(old.english, "Sentence 0.")
    }
}
