import XCTest
@testable import WLCore

final class WordLookupTests: XCTestCase {
    private func select(_ source: String, _ ranges: [NSRange], session: UUID = UUID()) throws -> LookupSelection {
        try LookupSelection(sessionID: session, captionID: UUID(), revision: 3, source: source, ranges: ranges)
    }
    func testActualUTF16SelectionAndLimits() throws {
        let source = "😀 The marginal benefit matters."
        let range = (source as NSString).range(of: "marginal benefit")
        let selected = try select(source, [range])
        XCTAssertEqual(selected.term, "marginal benefit"); XCTAssertEqual(selected.source, source)
        XCTAssertThrowsError(try select(source, []))
        XCTAssertThrowsError(try select(source, [NSRange(location: 0, length: 0)]))
        XCTAssertThrowsError(try select(source, [NSRange(location: 1, length: 1)]), "Split surrogate must be rejected")
        XCTAssertThrowsError(try select(source, [NSRange(location: NSNotFound, length: 1)]))
        XCTAssertThrowsError(try select(source, [NSRange(location: 4, length: Int.max)]))
        XCTAssertThrowsError(try select(source, [range, range]), "Multiple selections must never become a union")
        XCTAssertThrowsError(try select("   ", [NSRange(location: 0, length: 3)]))
        let ten = Array(repeating: "word", count: 10).joined(separator: " ")
        XCTAssertEqual(try select(ten, [NSRange(location: 0, length: ten.utf16.count)]).term, ten)
        let eleven = ten + " word"
        XCTAssertThrowsError(try select(eleven, [NSRange(location: 0, length: eleven.utf16.count)]))
        let long = String(repeating: "a", count: 121)
        XCTAssertThrowsError(try select(long, [NSRange(location: 0, length: 121)]))
    }
    func testClosingChangingSelectionAndRequestRejectLateResults() throws {
        let a = try select("one two", [NSRange(location: 0, length: 3)])
        let b = try select("one two", [NSRange(location: 4, length: 3)])
        var gate = LookupRequestGate(); gate.select(a); let first = gate.begin()
        XCTAssertTrue(gate.accepts(first, selection: a.id))
        gate.select(b); XCTAssertFalse(gate.accepts(first, selection: a.id))
        let second = gate.begin(); let retry = gate.begin()
        XCTAssertFalse(gate.accepts(second, selection: b.id)); XCTAssertTrue(gate.accepts(retry, selection: b.id))
        gate.close(); XCTAssertFalse(gate.accepts(retry, selection: b.id))
        let otherLesson = try select("two", [NSRange(location: 0, length: 3)])
        gate.select(otherLesson); XCTAssertFalse(gate.accepts(retry, selection: otherLesson.id))
    }
    func testPronunciationStopsBeforeCaptureAndRejectsRecording() {
        var state = LookupSpeechState()
        XCTAssertFalse(state.begin(recordingState: .recording, busy: false))
        XCTAssertFalse(state.begin(recordingState: .interrupted, busy: false))
        XCTAssertFalse(state.begin(recordingState: .paused, busy: true))
        XCTAssertTrue(state.begin(recordingState: .paused, busy: false)); XCTAssertTrue(state.speaking)
        state.stopBeforeRecording(); XCTAssertFalse(state.speaking)
        XCTAssertFalse(state.begin(recordingState: .recording, busy: false))
        XCTAssertTrue(state.begin(recordingState: .stopped, busy: false))
    }
    func testLookupUsageDedupAndOldJSONDoesNotConsumePostLessonBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        let post = UsageEntry(scope: .postLesson, model: "test", reserved: 250_000)
        try await store.reserveUsage(post, session: session.id)
        let entry = UsageEntry(scope: .lookup, model: "test")
        let meta = APIResponseMetadata(["id": "lookup-response", "usage": ["input_tokens": 80, "output_tokens": 20, "total_tokens": 100]])
        try await store.reserveUsage(entry, session: session.id)
        try await store.finishUsage(entry, metadata: meta, session: session.id)
        let duplicate = UsageEntry(scope: .lookup, model: "test")
        try await store.reserveUsage(duplicate, session: session.id)
        try await store.finishUsage(duplicate, metadata: meta, session: session.id)
        let totals = try await store.usageTotals(session.id)
        XCTAssertEqual(totals.lookup, 100); XCTAssertEqual(totals.total, 100)
        XCTAssertEqual(totals.chargedPostLesson, 250_000); XCTAssertEqual(totals.unknown, 1)
        let old = UsageEntry(scope: .live, model: "old")
        let decoded = try JSONDecoder().decode(UsageEntry.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(decoded.scope, .live); XCTAssertEqual(UsageTotals([decoded]).lookup, 0)
    }
}
