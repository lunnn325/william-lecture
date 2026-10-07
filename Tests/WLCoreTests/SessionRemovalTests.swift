import XCTest
@testable import WLCore

final class SessionRemovalTests: XCTestCase {
    private func fixture() async throws -> (URL, SessionStore, LectureSession, TranscriptSegment) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SessionStore(root: root)
        var session = LectureSession(course: "ECON1111"); session.state = .stopped
        session.updateRecordingDuration(42); session.audioFiles = ["audio.caf"]
        try await store.save(session)
        var segment = TranscriptSegment(start: 2, end: 6, english: "A social cost.")
        segment.status = .completed; segment.chinese = "社会成本。"
        try await store.append(segment, session: session.id)
        try Data([1, 2, 3]).write(to: store.folder(session.id).appendingPathComponent("audio.caf"))
        let exports = try await store.exportDirectory(session.id)
        try Data([4, 5, 6]).write(to: exports.appendingPathComponent("recording.m4a"))
        try await store.log(Diagnostic("speech_input_gap", offset: 0, fields: ["range_start": "0", "range_end": "1", "gap": "startup"]), session: session.id)
        try Data("preserved index".utf8).write(to: store.folder(session.id).appendingPathComponent("audio-index.jsonl"))
        return (root, store, session, segment)
    }
    private func rejects(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("A removed/active classroom must reject this operation", file: file, line: line) } catch { }
    }
    func testPermanentRemovalFencesCachedAndLateWritersAndExports() async throws {
        let (root, store, session, segment) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var other = LectureSession(course: "FINN2003"); other.state = .stopped; try await store.save(other)
        let document = LessonContent(sessionID: session.id, segments: [segment])
        _ = try await store.saveContent(document)
        _ = try await store.translationSnapshot(segment, session: session.id)
        _ = try await store.pending(session.id)
        try await store.deleteSession(session.id); try await store.deleteSession(session.id)
        let remaining = try await store.sessions(); XCTAssertEqual(remaining.map(\.id), [other.id])
        let entry = UsageEntry(scope: .live, model: "test")
        await rejects { try await store.save(session) }
        await rejects { try await store.append(segment, session: session.id) }
        await rejects { _ = try await store.translationSnapshot(segment, session: session.id) }
        await rejects { _ = try await store.pending(session.id) }
        await rejects { try await store.saveNote(LectureNote(offset: 2, text: "late"), session: session.id) }
        await rejects { _ = try await store.saveContent(document) }
        await rejects { try await store.log(Diagnostic("late"), session: session.id) }
        await rejects { try await store.appendFinal(SpeechPiece(text: "late", start: 0, end: 1), session: session.id) }
        await rejects { try await store.reserveUsage(entry, session: session.id) }
        await rejects { try await store.finishUsage(entry, metadata: APIResponseMetadata([:]), session: session.id) }
        await rejects { _ = try await store.export(session.id, language: .bilingual, markdown: false) }
        await rejects { _ = try await store.exportNotes(session.id, markdown: false) }
        await rejects { _ = try await store.exportDiagnostics(session.id) }
        await rejects { _ = try await store.exportStudy(session.id) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(session.id).path))
        let reopened = SessionStore(root: root); _ = try await reopened.recover()
        await rejects { try await reopened.save(session) }
    }
    func testAudioCleanupPreservesClassroomAndPreventsStaleMetadataRestoringAudio() async throws {
        let (root, store, session, segment) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let note = LectureNote(segmentID: segment.id, offset: 2, text: "Review this")
        try await store.saveNote(note, session: session.id)
        let entry = UsageEntry(scope: .live, model: "test"); try await store.reserveUsage(entry, session: session.id)
        var document = LessonContent(sessionID: session.id, segments: [segment]); document.state = .completed
        document.overview = "社会成本"; document.outline = [StudyNode(id: "cost", title: "社会成本", segmentIDs: [segment.id])]
        _ = try await store.saveContent(document)
        let transcript = try Data(contentsOf: store.folder(session.id).appendingPathComponent("transcript.jsonl"))
        let originalExport = try await store.export(session.id, language: .bilingual, markdown: true)
        let external = root.appendingPathComponent("external-copy.m4a"); try Data([9]).write(to: external)
        _ = try await store.clearAudio(session.id); _ = try await store.clearAudio(session.id)
        var stale = session; stale.audioStorage = .available; try await store.save(stale)
        let saved = try await store.sessions().first!; XCTAssertEqual(saved.audioStorage, .cleared)
        XCTAssertTrue(saved.audioFiles.isEmpty); XCTAssertEqual(saved.duration, 42); XCTAssertEqual(saved.recordedDuration, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(session.id).appendingPathComponent("audio.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(session.id).appendingPathComponent("Exports/recording.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalExport.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertEqual(try Data(contentsOf: store.folder(session.id).appendingPathComponent("transcript.jsonl")), transcript)
        let notes = try await store.notes(session.id), entries = try await store.usageEntries(session.id)
        XCTAssertEqual(notes, [note]); XCTAssertEqual(entries.first?.id, entry.id)
        let content = try await store.content(session.id); XCTAssertEqual(content?.outline, document.outline)
        let offsets = try await store.audioOffsets(session.id); XCTAssertTrue(offsets.isEmpty)
        await rejects { _ = try await store.exportDirectory(session.id, audio: true) }
        let text = try await store.export(session.id, language: .bilingual, markdown: false)
        XCTAssertTrue(try String(contentsOf: text, encoding: .utf8).contains("录音已清理"))
        _ = try await store.exportNotes(session.id, markdown: true); _ = try await store.exportStudy(session.id)
        _ = try await store.exportDiagnostics(session.id)
    }
    func testClearedIncompleteAudioKeepsGapsAndAllowsTextTranslation() async throws {
        let (root, store, session, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = TranscriptSegment(start: 8, end: 10, english: "Yes?"); try await store.append(source, session: session.id)
        let sources = try await store.segments(session.id)
        var document = LessonContent(sessionID: session.id, segments: sources); _ = try await store.saveContent(document)
        _ = try await store.clearAudio(session.id)
        let request = UUID(), started = try await store.beginGPT(source, session: session.id, request: request, at: Date())!
        _ = try await store.applyGPT(started, session: session.id, request: request, status: .completed, chinese: "是吗？")
        let repair = TranscriptSegment(start: 0, end: 1, english: "A missing word")
        let appended = try await store.appendRepaired(repair, session: session.id); XCTAssertFalse(appended)
        document.audioRepairWarning = nil; document.updatedAt = Date(); _ = try await store.saveContent(document)
        let saved = try await store.content(session.id)
        XCTAssertEqual(saved?.audioRepairWarning, "录音已清理，未补转写的内容无法恢复")
        let segments = try await store.segments(session.id); XCTAssertEqual(segments.last?.finalChinese, "是吗？")
        let gaps = try await store.audioRepairRanges(session.id); XCTAssertEqual(gaps, [.init(start: 0, end: 1)])
    }
    func testInterruptedDeletionAndCleanupResumeBeforeQueueRecovery() async throws {
        let (root, store, deleted, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let markers = root.appendingPathComponent(".deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: false)
        try Data().write(to: markers.appendingPathComponent(deleted.id.uuidString), options: .atomic)
        var clearing = LectureSession(course: "FINN3001"); clearing.state = .stopped; clearing.audioStorage = .clearing
        clearing.updateRecordingDuration(12); try await store.save(clearing)
        try Data([1]).write(to: store.folder(clearing.id).appendingPathComponent("remaining.caf"))
        let reopened = SessionStore(root: root); let issues = try await reopened.recover(); XCTAssertTrue(issues.isEmpty)
        let sessions = try await reopened.sessions(); XCTAssertEqual(sessions.map(\.id), [clearing.id])
        XCTAssertEqual(sessions.first?.audioStorage, .cleared); XCTAssertEqual(sessions.first?.duration, 12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(deleted.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(clearing.id).appendingPathComponent("remaining.caf").path))
    }
    func testActiveSessionsCannotBeRemovedAndLegacyMetadataRemainsReadable() async throws {
        let (root, store, session, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try Data(contentsOf: store.folder(session.id).appendingPathComponent("session.json"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["audioStorage"])
        for state in [SessionState.recording, .paused, .interrupted] {
            var active = session; active.state = state; try await store.save(active)
            await rejects { try await store.deleteSession(session.id) }
            await rejects { _ = try await store.clearAudio(session.id) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(session.id).appendingPathComponent("audio.caf").path))
        }
    }
    func testRemovalDoesNotFollowClassroomSymlinkOutsideRoot() async throws {
        let (root, store, session, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.moveItem(at: store.folder(session.id), to: outside)
        try FileManager.default.createSymbolicLink(at: store.folder(session.id), withDestinationURL: outside)
        await rejects { try await store.deleteSession(session.id) }
        await rejects { _ = try await store.clearAudio(session.id) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("audio.caf").path))
    }
}
