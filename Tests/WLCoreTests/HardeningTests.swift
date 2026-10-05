import Darwin
import XCTest
@testable import WLCore

private actor StressTranslator {
    private var active = 0
    private var maximum = 0
    private var attempts: [UUID: Int] = [:]
    func translate(_ segment: TranscriptSegment, delta: @escaping @Sendable (String) async -> Void) async throws -> String {
        active += 1; maximum = max(maximum, active); defer { active -= 1 }
        attempts[segment.id, default: 0] += 1
        if Int(segment.start) % 452 == 0 && attempts[segment.id] == 1 { throw APIError(status: 500, retryAfter: 0) }
        await delta("数字 "); await delta("\(Int(segment.start))。")
        return "数字 \(Int(segment.start))。"
    }
    func snapshot() -> (maximum: Int, counts: [UUID: Int]) { (maximum, attempts) }
}

final class HardeningTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testRecoveryRestoresInteriorHoleAndOneDamagedSessionDoesNotBlockOthers() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let valid = LectureSession(course: "Good"), damaged = LectureSession(course: "Damaged")
        try await store.save(valid); try await store.save(damaged)
        for index in 0..<3 {
            let piece = SpeechPiece(text: "Sentence \(index).", start: Double(index * 4), end: Double(index * 4 + 4))
            try await store.appendFinal(piece, session: valid.id)
            if index != 1 { try await store.append(TranscriptSegment(start: piece.start, end: piece.end, english: piece.text), session: valid.id) }
        }
        try Data("bad JSON\n".utf8).write(to: store.folder(damaged.id).appendingPathComponent("transcript.jsonl"))
        let issues = try await store.recover(); XCTAssertEqual(issues.count, 1)
        let records = try await store.segments(valid.id); XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[1].english, "Sentence 1.")
        let second = try await store.recover(); XCTAssertEqual(second.count, 1)
        let unchanged = try await store.segments(valid.id); XCTAssertEqual(unchanged.count, 3)
    }
    func testRecoveryDurationUsesRecordedOffsetsAndNotTimeOfRelaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let session = LectureSession(course: "Yesterday", now: Date(timeIntervalSince1970: 1000))
        try await store.save(session)
        try await store.log(Diagnostic("health", offset: 123), session: session.id)
        try await store.recover()
        let sessions = try await store.sessions()
        let result = try XCTUnwrap(sessions.first)
        XCTAssertEqual(result.duration, 123); XCTAssertEqual(result.stoppedAt, session.startedAt.addingTimeInterval(123))
    }
    func testExportsAreImmutableSnapshotsAndDiagnosticSecretsAreRedacted() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let session = LectureSession(course: "Snapshot")
        try await store.save(session)
        var segment = TranscriptSegment(start: 0, end: 2, english: "12.5 percent.")
        try await store.append(segment, session: session.id)
        let key = ["sk", "proj"].joined(separator: "-") + "-TEST_SECRET_123456789"
        try await store.log(Diagnostic("test_error", fields: ["error": "Bearer \(key)"]), session: session.id)
        let first = try await store.export(session.id, language: .bilingual, markdown: false)
        let diag = try await store.exportDiagnostics(session.id)
        let before = try Data(contentsOf: first); let diagnosticBefore = try Data(contentsOf: diag)
        segment.status = .completed; segment.chinese = "12.5%。"; try await store.append(segment, session: session.id)
        try await store.log(Diagnostic("later"), session: session.id)
        let second = try await store.export(session.id, language: .bilingual, markdown: false)
        XCTAssertNotEqual(first, second); XCTAssertEqual(try Data(contentsOf: first), before)
        XCTAssertEqual(try Data(contentsOf: diag), diagnosticBefore)
        let diagnosticText = String(decoding: diagnosticBefore, as: UTF8.self)
        XCTAssertFalse(diagnosticText.contains(key)); XCTAssertTrue(diagnosticText.contains("REDACTED"))
        XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains("12.5%。"))
    }
    func testDeadlineReturnsWithoutAwaitingUncooperativeOperation() async throws {
        let done = expectation(description: "Late operation eventually finishes")
        do {
            let _: Int = try await AsyncDeadline.run(seconds: 0.01) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
                }
                done.fulfill(); return 42
            }
            XCTFail("Deadline should win")
        } catch { XCTAssertTrue(error.localizedDescription.contains("deadline")) }
        await fulfillment(of: [done], timeout: 2)
    }
    func testDeadlineHonorsCallerCancellation() async throws {
        let task = Task { try await AsyncDeadline.run(seconds: 10) { try await Task.sleep(for: .seconds(10)); return 1 } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled caller must return") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testAcceleratedThreeHourBacklogRecoveryTranslationAndExport() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(); let baseline = residentBytes(); var peak = baseline
        let store = SessionStore(root: root)
        let session = LectureSession(course: "Three-hour accelerated stress", now: Date().addingTimeInterval(-10800))
        try await store.save(session)
        var cursor = FinalSpeechCursor(); var buffer = SentenceBuffer(); var accepted = 0
        for index in 0..<2700 {
            let piece = SpeechPiece(text: "The marginal cost is \(index) percent today.", start: Double(index * 4), end: Double(index * 4 + 4),
                                    receivedAt: session.startedAt.addingTimeInterval(Double(index * 4 + 4)))
            XCTAssertTrue(cursor.accept(piece)); accepted += 1
            for _ in 0..<3 { XCTAssertFalse(cursor.accept(piece)) }
            try await store.appendFinal(piece, session: session.id)
            if let segment = buffer.append(piece), index < 2500, index != 1234 {
                try await store.append(segment, session: session.id)
            }
        }
        for second in 0..<10800 {
            try await store.log(Diagnostic("health", offset: Double(second), fields: ["captured_seconds": "\(second)"]), session: session.id)
        }
        peak = max(peak, residentBytes())
        let reopened = SessionStore(root: root)
        let issues = try await reopened.recover(); XCTAssertTrue(issues.isEmpty)
        let recovered = try await reopened.segments(session.id)
        XCTAssertEqual(recovered.count, 2700); XCTAssertEqual(Set(recovered.map(\.english)).count, 2700)
        let recoveredSessions = try await reopened.sessions()
        let sessionSnapshot = try XCTUnwrap(recoveredSessions.first)
        let probe = StressTranslator()
        let worker = TranslationWorker(store: reopened, config: TranslatorConfiguration(mock: false, model: "stress-injected", key: nil),
            session: sessionSnapshot, operation: { segment, delta in try await probe.translate(segment, delta: delta) })
        let translated = expectation(description: "Three-hour backlog drains"); translated.expectedFulfillmentCount = 2700
        worker.onUpdate = { segment in
            if segment.status == .completed {
                peak = max(peak, self.residentBytes()); translated.fulfill()
            }
        }
        worker.kick()
        await fulfillment(of: [translated], timeout: 120)
        await worker.waitForCancellation()
        let resources = worker.resourceCounts; XCTAssertEqual(resources.requests, 0); XCTAssertEqual(resources.streams, 0)
        let observed = await probe.snapshot(); XCTAssertLessThanOrEqual(observed.maximum, 2)
        XCTAssertEqual(observed.counts.count, 2700); XCTAssertTrue(observed.counts.values.allSatisfy { $0 <= 2 })
        let pending = try await reopened.pending(session.id); XCTAssertTrue(pending.isEmpty)
        let results = try await reopened.segments(session.id); XCTAssertTrue(results.allSatisfy { $0.status == .completed })
        for language in ExportLanguage.allCases {
            for markdown in [false, true] {
                let exported = try await reopened.export(session.id, language: language, markdown: markdown)
                let text = try String(contentsOf: exported, encoding: .utf8)
                XCTAssertEqual(text.components(separatedBy: " – ").count - 1, 2700)
                XCTAssertFalse(text.contains("中文缺失"))
            }
        }
        var diagnosticCount = 0
        let diagnostic = try await reopened.exportDiagnostics(session.id)
        try JSONLines.scan(Diagnostic.self, at: diagnostic) { _ in diagnosticCount += 1 }
        XCTAssertGreaterThan(diagnosticCount, 18900)
        peak = max(peak, residentBytes())
        let growth = peak > baseline ? peak - baseline : 0
        XCTAssertLessThan(growth, 128 * 1024 * 1024, "Accelerated text workload must not retain an unbounded task/stream backlog")
        let metrics: [String: Any] = ["simulated_seconds": 10800, "segments": accepted, "duplicate_finals_rejected": 8100,
            "diagnostic_records": diagnosticCount, "max_in_flight": observed.maximum, "pending_at_end": pending.count,
            "active_requests_at_end": resources.requests, "stream_entries_at_end": resources.streams,
            "rss_baseline_mb": Double(baseline) / 1048576, "rss_peak_mb": Double(peak) / 1048576,
            "rss_growth_mb": Double(growth) / 1048576, "wall_seconds": Date().timeIntervalSince(started)]
        print("WL_STRESS_REPORT " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), as: UTF8.self))
    }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        } }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
