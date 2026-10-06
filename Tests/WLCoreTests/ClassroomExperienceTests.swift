import XCTest
@testable import WLCore

final class ClassroomExperienceTests: XCTestCase {
    func testNoteUpsertSurvivesReopenWithoutChangingTranscript() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        let source = segment(12); try await store.append(source, session: session.id)
        let before = try Data(contentsOf: store.folder(session.id).appendingPathComponent("transcript.jsonl"))
        var note = LectureNote(segmentID: source.id, offset: 12, english: source.english)
        try await store.saveNote(note, session: session.id)
        note.text = "Check marginal cost"; try await store.saveNote(note, session: session.id)
        let reopened = SessionStore(root: root), saved = try await reopened.notes(session.id)
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved.first?.text, note.text)
        XCTAssertEqual(try Data(contentsOf: store.folder(session.id).appendingPathComponent("transcript.jsonl")), before)
    }
    func testRemovingMarkerKeepsTextAndEmptyTombstoneHidesNote() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "FINN")
        try await store.save(session)
        var note = LectureNote(offset: 5, text: "review")
        try await store.saveNote(note, session: session.id)
        note.marked = false; try await store.saveNote(note, session: session.id)
        let retained = try await store.notes(session.id); XCTAssertEqual(retained.count, 1)
        note.text = ""; try await store.saveNote(note, session: session.id)
        let removed = try await store.notes(session.id); XCTAssertTrue(removed.isEmpty)
    }
    func testLegacySessionWithoutNotesAndInterruptedNoteTailRecover() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "Legacy")
        try await store.save(session)
        let empty = try await store.notes(session.id); XCTAssertTrue(empty.isEmpty)
        let note = LectureNote(offset: 7, english: "unfinished source")
        try await store.saveNote(note, session: session.id)
        let file = store.folder(session.id).appendingPathComponent("notes.jsonl")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{incomplete".utf8)); try handle.close()
        let restored = try await store.notes(session.id); XCTAssertEqual(restored.map(\.id), [note.id])
        let another = LectureNote(offset: 9); try await store.saveNote(another, session: session.id)
        let repaired = try await store.notes(session.id); XCTAssertEqual(repaired.count, 2)
    }
    func testInvalidNoteCannotCreatePhantomSession() async {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        do { try await store.saveNote(LectureNote(offset: 0), session: UUID()); XCTFail("Must reject absent session") } catch {}
        let history = try? await store.sessions(); XCTAssertEqual(history?.count, 0)
    }
    func testNotesExportIsSeparateUTF8WithSnapshotIdentity() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "复习")
        try await store.save(session)
        try await store.saveNote(LectureNote(offset: 65, english: "social cost", text: "核对外部性"), session: session.id)
        for markdown in [false, true] {
            let url = try await store.exportNotes(session.id, markdown: markdown), content = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(content.contains("核对外部性")); XCTAssertTrue(content.contains("01:05")); XCTAssertTrue(content.contains("快照"))
            XCTAssertEqual(url.pathExtension, markdown ? "md" : "txt")
        }
    }
    func testReadingWindowDoesNotMoveWhenNewSpeechArrivesButFinalStillUpgrades() {
        var feed = CaptionFeed(); let first = segment(0), second = segment(3)
        feed.merge([first]); feed.suspend(); feed.merge([second])
        var final = first; final.status = .completed; final.chinese = "最终中文"
        feed.merge([final]); feed.merge([first])
        XCTAssertEqual(feed.rows.map(\.id), [first.id]); XCTAssertEqual(feed.rows.first?.finalChinese, "最终中文")
        XCTAssertTrue(feed.hasNewContent); XCTAssertFalse(feed.following)
        feed.resume(latest: [final, second]); XCTAssertEqual(feed.rows.count, 2); XCTAssertFalse(feed.hasNewContent)
    }
    func testThreeHoursCaptionTrafficKeepsFeedBoundedAndIdentityUnique() {
        var feed = CaptionFeed(); var maximum = 0
        for index in 0..<3600 { feed.merge([segment(Double(index) * 3)]); maximum = max(maximum, feed.rows.count) }
        XCTAssertEqual(maximum, 180); XCTAssertEqual(feed.rows.count, 180)
        let last = feed.rows.last!.id; feed.suspend()
        for index in 3600..<7200 { feed.merge([segment(Double(index) * 3)]) }
        XCTAssertEqual(feed.rows.count, 180); XCTAssertEqual(feed.rows.last?.id, last)
        let older = (0..<500).map { segment(Double($0)) }
        feed.prepend(older + older); feed.merge([])
        XCTAssertEqual(feed.rows.count, 360); XCTAssertEqual(Set(feed.rows.map(\.id)).count, feed.rows.count)
        print("V1_FEED_STRESS: equivalent_hours=3 speech_segments=3600 active_rows_max=\(maximum) reading_rows_max=\(feed.rows.count)")
    }
    func testPlaybackUsesRecordedTimeAtChunkBoundaryAndEnd() throws {
        let axis = try PlaybackTimeline(slices: [.init(file: "a.caf", start: 0, duration: 10), .init(file: "b.caf", start: 10, duration: 20)])
        XCTAssertEqual(axis.duration, 30)
        XCTAssertEqual(axis.position(at: 10), PlaybackPosition(index: 1, fileSeconds: 0))
        XCTAssertEqual(axis.position(at: 999), PlaybackPosition(index: 1, fileSeconds: 20))
        XCTAssertEqual(axis.position(at: -2), PlaybackPosition(index: 0, fileSeconds: 0))
        XCTAssertNil(axis.position(at: .nan))
    }
    func testLegacyPauseGapSeeksNextRealAudioWithoutInventingSamples() throws {
        let axis = try PlaybackTimeline(slices: [.init(file: "a.caf", start: 0, duration: 10), .init(file: "b.caf", start: 40, duration: 10)])
        XCTAssertEqual(axis.duration, 50); XCTAssertEqual(axis.position(at: 25), PlaybackPosition(index: 1, fileSeconds: 0))
    }
    func testInvalidPlaybackMetadataRejectsTraversalOverlapAndZeroDuration() {
        for invalid in [PlaybackSlice(file: "../a.caf", start: 0, duration: 10), .init(file: "a.caf", start: 0, duration: 0), .init(file: "a.caf", start: .nan, duration: 1)] {
            XCTAssertThrowsError(try PlaybackTimeline(slices: [invalid]))
        }
        XCTAssertThrowsError(try PlaybackTimeline(slices: [.init(file: "a", start: 0, duration: 10), .init(file: "b", start: 5, duration: 10)]))
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func segment(_ start: Double) -> TranscriptSegment { TranscriptSegment(start: start, end: start + 2, english: "Recorded sentence at \(start)") }
}
