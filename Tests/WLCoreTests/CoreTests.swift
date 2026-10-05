import XCTest
@testable import WLCore

final class CoreTests: XCTestCase {
    func testFinalBufferDoesNotDuplicateReplayOrOverlappingFinal() {
        var buffer = SentenceBuffer()
        let piece = SpeechPiece(text: "Social cost exceeds private cost.", start: 1, end: 4)
        XCTAssertEqual(buffer.append(piece)?.english, piece.text)
        XCTAssertNil(buffer.append(piece))
        XCTAssertNil(buffer.append(SpeechPiece(text: "replayed earlier result", start: 0, end: 3)))
        XCTAssertEqual(buffer.append(SpeechPiece(text: "Next sentence.", start: 4, end: 7))?.start, 4)
    }
    func testFinalFragmentsBatchThenFlushAfterQuietTime() {
        let now = Date(timeIntervalSince1970: 1234.123)
        var buffer = SentenceBuffer(quietSeconds: 0.8)
        XCTAssertNil(buffer.append(SpeechPiece(text: "marginal social", start: 0, end: 2, receivedAt: now)))
        XCTAssertNil(buffer.append(SpeechPiece(text: "cost", start: 2, end: 3, receivedAt: now.addingTimeInterval(0.5))))
        XCTAssertNil(buffer.flushIfQuiet(now: now.addingTimeInterval(1)))
        let result = buffer.flushIfQuiet(now: now.addingTimeInterval(1.4))
        XCTAssertEqual(result?.english, "marginal social cost")
        XCTAssertEqual(result?.end, 3)
        XCTAssertNil(buffer.flush())
    }
    func testLongFinalizedRunHasBoundedBuffer() {
        var buffer = SentenceBuffer(maxWords: 3)
        XCTAssertNil(buffer.append(SpeechPiece(text: "one two", start: 0, end: 1)))
        XCTAssertEqual(buffer.append(SpeechPiece(text: "three", start: 1, end: 2))?.english, "one two three")
    }
    func testJSONLRetainsMillisecondPrecisionAndIgnoresInterruptedTail() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.jsonl")
        let original = TranscriptSegment(start: 0, end: 1, english: "test", receivedAt: Date(timeIntervalSince1970: 1234.12345))
        try JSONLines.append(original, to: url)
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"crashed\":".utf8)); try handle.close()
        var decoded: [TranscriptSegment] = []
        try JSONLines.scan(TranscriptSegment.self, at: url) { decoded.append($0) }
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].receivedAt.timeIntervalSince1970, original.receivedAt.timeIntervalSince1970, accuracy: 0.0001)
        try JSONLines.append(original, to: url)
        var count = 0; try JSONLines.scan(TranscriptSegment.self, at: url) { _ in count += 1 }
        XCTAssertEqual(count, 2, "Reopening a torn journal must repair its tail before appending")
    }
    func testMalformedCompleteJournalLineIsReported() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.jsonl")
        try Data("{bad JSON}\n".utf8).write(to: url)
        XCTAssertThrowsError(try JSONLines.scan(TranscriptSegment.self, at: url) { _ in })
    }
    func testPersistedUpdatesRecoverOneRecordAndPendingWork() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(root: directory)
        let session = LectureSession(course: "ECON1111"); try await store.save(session)
        var segment = TranscriptSegment(start: 0, end: 3, english: "Tax is 12.5%.")
        try await store.append(segment, session: session.id)
        segment.submittedAt = Date(); segment.attempts = 1; try await store.append(segment, session: session.id)
        let reopened = try SessionStore(root: directory)
        let pending = try await reopened.pending(session.id)
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending[0].attempts, 1)
        segment.chinese = "税率为 12.5%。"; segment.status = .completed; try await reopened.append(segment, session: session.id)
        let records = try await reopened.segments(session.id)
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0].chinese, segment.chinese)
        let remaining = try await reopened.pending(session.id); XCTAssertTrue(remaining.isEmpty)
    }
    func testProcessRecoveryPreservesUnbatchedFinalWordsAndAudioNames() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(root: directory)
        let session = LectureSession(course: "FINN"); try await store.save(session)
        try Data().write(to: store.folder(session.id).appendingPathComponent("audio-00000.caf"))
        try await store.appendFinal(SpeechPiece(text: "incomplete sentence", start: 0, end: 2), session: session.id)
        try await store.recover(); try await store.recover()
        let recovered = try await store.sessions(); let words = try await store.segments(session.id)
        XCTAssertEqual(recovered.first?.state, .recovered)
        XCTAssertEqual(recovered.first?.audioFiles, ["audio-00000.caf"])
        XCTAssertEqual(words.count, 1); XCTAssertEqual(words[0].english, "incomplete sentence")
    }
    func testExportLanguagesNumbersMissingContentAndMockLabels() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(root: directory); let session = LectureSession(course: "经济学"); try await store.save(session)
        var complete = TranscriptSegment(start: 1, end: 2, english: "12.5% Pigouvian tax.")
        complete.chinese = "12.5% 庇古税。"; complete.status = .completed; try await store.append(complete, session: session.id)
        var mock = TranscriptSegment(start: 3, end: 4, english: "Mock example."); mock.chinese = "模拟"; mock.status = .mock; try await store.append(mock, session: session.id)
        try await store.append(TranscriptSegment(start: 5, end: 6, english: "Offline sentence."), session: session.id)
        try await store.log(Diagnostic("interruption", offset: 7, fields: ["gap": "audio gap"]), session: session.id)
        let enURL = try await store.export(session.id, language: .english, markdown: false)
        let zhURL = try await store.export(session.id, language: .chinese, markdown: true)
        let en = try String(contentsOf: enURL, encoding: .utf8); let zh = try String(contentsOf: zhURL, encoding: .utf8)
        XCTAssertTrue(en.contains("12.5% Pigouvian tax.")); XCTAssertFalse(en.contains("12.5% 庇古税。"))
        XCTAssertTrue(zh.contains("12.5% 庇古税。")); XCTAssertFalse(zh.contains("Pigouvian"))
        XCTAssertTrue(zh.contains("MOCK")); XCTAssertTrue(zh.contains("中文缺失")); XCTAssertTrue(zh.contains("audio gap"))
    }
    func testSSESingleLineAndMultiLineData() throws {
        var parser = SSEParser()
        XCTAssertNil(parser.line(": keepalive"))
        let json = try XCTUnwrap(parser.line("data: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}"))
        if case .delta(let text) = try TranslationEvent.decode(json) { XCTAssertEqual(text, "你好") } else { XCTFail() }
        XCTAssertNil(parser.line(""))
        XCTAssertNil(parser.line("data: {\"type\":"))
        let second = try XCTUnwrap(parser.line("data: \"response.completed\"}"))
        if case .completed = try TranslationEvent.decode(second) { } else { XCTFail() }
    }
    func testIncompleteAndRefusedStreamsAreNeverSuccessful() {
        for type in ["response.failed", "response.incomplete", "error", "response.refusal.delta"] {
            XCTAssertThrowsError(try TranslationEvent.decode(["type": type]))
        }
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
}
