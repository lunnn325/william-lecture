import XCTest
@testable import WLCore

final class LessonContentTests: XCTestCase {
    func testCorrectionExportPreservesRawAndRejectsOldRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let session = LectureSession(course: "ECON1111")
        try await store.save(session)
        var source = TranscriptSegment(start: 1, end: 3, english: "social costs")
        source.localEnabled = true; source.localChinese = "本机版本"; source.localRevision = 1; source.localSourceText = source.english
        try await store.append(source, session: session.id)
        var content = LessonContent(sessionID: session.id, segments: [source])
        content.corrected = [CorrectedSegment(source: source, english: "Social costs.", chinese: "社会成本。")]
        content.state = .completed
        let saved = try await store.saveContent(content); XCTAssertTrue(saved)
        let raw = try await store.segments(session.id); XCTAssertEqual(raw[0].english, "social costs")
        let finalURL = try await store.export(session.id, language: .bilingual, markdown: false)
        let originalURL = try await store.export(session.id, language: .bilingual, markdown: false, original: true)
        XCTAssertTrue(try String(contentsOf: finalURL, encoding: .utf8).contains("社会成本。"))
        XCTAssertTrue(try String(contentsOf: originalURL, encoding: .utf8).contains("本机版本"))
        source.english = "private costs"; source.revision = 2; try await store.append(source, session: session.id)
        let rejected = try await store.saveContent(content); XCTAssertFalse(rejected)
        let staleURL = try await store.export(session.id, language: .english, markdown: true)
        XCTAssertFalse(try String(contentsOf: staleURL, encoding: .utf8).contains("Social costs."))
    }
    func testUsageDeduplicatesResponseAndKeepsUnknownReservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let s = LectureSession(course: "FINN2004"); try await store.save(s)
        let first = UsageEntry(scope: .postLesson, model: "test", reserved: 245_000)
        try await store.reserveUsage(first, session: s.id)
        do { try await store.reserveUsage(UsageEntry(scope: .postLesson, model: "test", reserved: 6000), session: s.id); XCTFail("must refuse overspend") } catch { }
        let unknown = try await store.usageTotals(s.id); XCTAssertEqual(unknown.chargedPostLesson, 245_000); XCTAssertEqual(unknown.unknown, 1)
        let metadata = APIResponseMetadata(["id": "response-1", "usage": ["input_tokens": 20, "output_tokens": 10, "total_tokens": 30]])
        try await store.finishUsage(first, metadata: metadata, session: s.id)
        let duplicate = UsageEntry(scope: .postLesson, model: "test", reserved: 100)
        try await store.reserveUsage(duplicate, session: s.id); try await store.finishUsage(duplicate, metadata: metadata, session: s.id)
        let totals = try await store.usageTotals(s.id); XCTAssertEqual(totals.total, 30); XCTAssertEqual(totals.input, 20); XCTAssertEqual(totals.chargedPostLesson, 30)
    }
    func testRepairRangesDoNotReplayCoveredSpeechOrDuplicateInsertedText() async throws {
        let ranges = AudioRepairRange.uncovered([.init(start: 0, end: 5), .init(start: 4, end: 10)], covered: [.init(start: 2, end: 8)])
        XCTAssertEqual(ranges, [.init(start: 0, end: 2), .init(start: 8, end: 10)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let s = LectureSession(course: "FINN3001"); try await store.save(s)
        let piece = TranscriptSegment(start: 0, end: 2, english: "Net present value")
        let first = try await store.appendRepaired(piece, session: s.id)
        let duplicate = try await store.appendRepaired(piece, session: s.id)
        XCTAssertTrue(first); XCTAssertFalse(duplicate)
    }
    func testReopenKeepsProgressAndRejectsLateSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root); let s = LectureSession(course: "FINN2003"); try await store.save(s)
        let source = TranscriptSegment(start: 1, end: 2, english: "CBDC")
        try await store.append(source, session: s.id)
        var first = LessonContent(sessionID: s.id, segments: [source]); first.state = .revising
        first.corrected = [.init(source: source, english: "CBDC", chinese: "央行数字货币")]
        _ = try await store.saveContent(first)
        var next = first; next.state = .generating; next.updatedAt = first.updatedAt.addingTimeInterval(1)
        _ = try await store.saveContent(next)
        let late = try await store.saveContent(first); XCTAssertFalse(late)
        let reopened = SessionStore(root: root); _ = try await reopened.recover()
        let persisted = try await reopened.content(s.id); XCTAssertEqual(persisted?.state, .generating); XCTAssertEqual(persisted?.corrected.count, 1)
    }
    func testReadingTimeAndProtectedFinancialNumbers() {
        XCTAssertEqual(SessionStore.readingTime(32), "00:32")
        XCTAssertEqual(SessionStore.readingTime(2538), "42:18")
        XCTAssertEqual(SessionStore.readingTime(7205), "2:00:05")
        XCTAssertNotEqual(LessonAPI.protectedTokens("not 1.25 USD"), LessonAPI.protectedTokens("1.25 USD"))
        XCTAssertNotEqual(LessonAPI.protectedTokens("1.25 USD"), LessonAPI.protectedTokens("1.52 USD"))
        XCTAssertTrue(CourseProfiles.context("FINN3001").contains("np.arange"))
    }
    func testStoppedReconciliationSupersedesOrphanAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        var session = LectureSession(course: "ECON1111"); session.state = .stopped
        try await store.save(session)
        let source = TranscriptSegment(start: 0, end: 2, english: "A tax changes incentives.")
        try await store.append(source, session: session.id)
        let token = UUID()
        let orphan = try await store.beginGPT(source, session: session.id, request: token, at: Date())
        XCTAssertNotNil(orphan)
        let reopened = SessionStore(root: root); _ = try await reopened.recover()
        try await reopened.repairTranslation(source, chinese: "税收改变激励。", session: session.id)
        let stale = try await reopened.applyGPT(orphan!, session: session.id, request: token, status: .completed, chinese: "旧译文")
        XCTAssertNil(stale)
        let final = try await reopened.segments(session.id)
        XCTAssertEqual(final.first?.finalChinese, "税收改变激励。")
        XCTAssertNil(final.first?.gptRequestID)
    }
    func testEnglishPreviewIsImmediateAndNeverChangesStableBuffer() {
        var buffer = SentenceBuffer()
        let word = SpeechPiece(text: "The", start: 0, end: 0.2)
        XCTAssertEqual(LiveEnglishPreview.text(partial: word, buffer: buffer, finalizedEnd: -1), "The")
        XCTAssertEqual(LiveEnglishPreview.text(partial: .init(text: "The social cost", start: 0, end: 0.8), buffer: buffer, finalizedEnd: -1), "The social cost")
        XCTAssertTrue(buffer.pendingText.isEmpty)
        _ = buffer.append(.init(text: "The cost", start: 0, end: 1))
        let overlap = SpeechPiece(text: "The cost is not zero", start: 0, end: 2)
        XCTAssertEqual(LiveEnglishPreview.text(partial: overlap, buffer: buffer, finalizedEnd: 1), "The cost is not zero")
        XCTAssertEqual(buffer.pendingText, "The cost")
        let tail = SpeechPiece(text: "is not zero", start: 1, end: 2)
        XCTAssertEqual(LiveEnglishPreview.text(partial: tail, buffer: buffer, finalizedEnd: 1), "The cost is not zero")
        XCTAssertNil(LiveEnglishPreview.text(partial: tail, buffer: buffer, finalizedEnd: 2))
        XCTAssertNil(LiveEnglishPreview.text(partial: .init(text: "", start: 1, end: 2), buffer: buffer, finalizedEnd: 1))
    }
}
