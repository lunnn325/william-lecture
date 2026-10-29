import XCTest
@testable import WLCore

final class Version119Tests: XCTestCase {
    func testLocalQueueIndexTracksNewRevisionsAndClassroomSwitches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        var first = TranscriptSegment(start: 0, end: 2, english: "First."); first.localEnabled = true
        var last = TranscriptSegment(start: 5, end: 7, english: "Last."); last.localEnabled = true
        try await store.append(first, session: session.id); try await store.append(last, session: session.id)
        let oldest = try await store.localPending(session.id); XCTAssertEqual(oldest?.id, first.id)
        let newest = try await store.localPending(session.id, newestFirst: true); XCTAssertEqual(newest?.id, last.id)
        let token = UUID(); let begun = try await store.beginLocal(first, session: session.id, request: token)
        _ = try await store.applyLocal(try XCTUnwrap(begun), session: session.id, request: token, chinese: "第一句", at: Date())
        let pending = try await store.localPending(session.id); XCTAssertEqual(pending?.id, last.id)
        first.revision = 2; first.english = "Corrected first."
        try await store.append(first, session: session.id)
        let revised = try await store.localPending(session.id); XCTAssertEqual(revised?.id, first.id)
        let other = LectureSession(course: "FINN2003"); try await store.save(other)
        let empty = try await store.localPending(other.id); XCTAssertNil(empty)
        let restored = try await store.localPending(session.id); XCTAssertEqual(restored?.id, first.id)
    }
    func testAliasBatchAcceptsReorderingAndIsolatesDuplicatesUnknownAndMissing() {
        let a = TranscriptSegment(start: 0, end: 2, english: "It is not five."), b = TranscriptSegment(start: 3, end: 4, english: "A name.")
        let map = RevisionBatch([a, b])
        let result = map.resolve([.init(id: "s2", english: "Ada", chinese: "艾达"),
            .init(id: "s1", english: "It is six.", chinese: "是六。"),
            .init(id: "s1", english: "wrong duplicate", chinese: "重复"), .init(id: "elsewhere", english: "X", chinese: "串句")])
        XCTAssertEqual(result.values[a.id]?.english, "It is six.")
        XCTAssertEqual(result.values[b.id]?.english, "Ada")
        XCTAssertEqual(Set(result.issues), ["duplicate:s1", "unknown:elsewhere"])
        XCTAssertEqual(map.resolve([.init(id: "s2", english: "Ada", chinese: "艾达")]).issues, ["missing:s1"])
        XCTAssertEqual(a.english, "It is not five.")
    }
    func testConversationPersistsSnapshotUsesNewContentAndRejectsLateReplies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        let first = TranscriptSegment(start: 0, end: 2, english: "Original speech.")
        try await store.append(first, session: session.id)
        let turn = try await store.beginConversation(session.id, question: "Explain this.")
        XCTAssertTrue(turn.input.contains("Original speech."))
        let committed = try await store.updateConversation(session.id, message: turn.message.id, request: turn.message.requestID!, text: "回答", state: "completed")
        XCTAssertTrue(committed)
        let duplicate = try await store.updateConversation(session.id, message: turn.message.id, request: turn.message.requestID!, text: "迟到", state: "completed")
        XCTAssertFalse(duplicate)
        try await store.append(TranscriptSegment(start: 3, end: 5, english: "New content."), session: session.id)
        let next = try await store.beginConversation(session.id, question: "What happened next?")
        XCTAssertTrue(next.input.contains("New content.")); XCTAssertTrue(next.input.contains("回答"))
        XCTAssertEqual(next.message.snapshotEnd, 5)
        let reopened = SessionStore(root: root)
        let recovered = try await reopened.recoverConversation(session.id)
        XCTAssertEqual(recovered.last?.state, "interrupted")
        let retry = try await reopened.beginConversation(session.id, question: "", retry: next.message.id)
        XCTAssertNotEqual(retry.message.requestID, next.message.requestID)
        let stale = try await reopened.updateConversation(session.id, message: next.message.id, request: next.message.requestID!, text: "旧结果", state: "completed")
        XCTAssertFalse(stale)
        let other = LectureSession(course: "FINN2004"); try await store.save(other)
        let isolated = try await store.conversation(other.id); XCTAssertTrue(isolated.isEmpty)
    }
    func testStudyIsManualAndConcurrentRevisionCannotEraseGeneratedFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        let row = TranscriptSegment(start: 0, end: 2, english: "Social coast.")
        try await store.append(row, session: session.id)
        var revision = LessonContent(sessionID: session.id, segments: [row]); revision.processingVersion = 119
        XCTAssertNil(revision.study)
        _ = try await store.saveContent(revision)
        let (_, _, token) = try await store.beginStudy(session.id)
        let node = StudyNode(id: "cost", title: "成本", segmentIDs: [row.id])
        let saved = try await store.finishStudy(session.id, request: token, title: "摘要", overview: "内容", outline: [node], state: .completed)
        XCTAssertTrue(saved)
        revision.corrected = [CorrectedSegment(source: row, english: "Social cost.", chinese: "社会成本。")]
        revision.state = .completed; revision.updatedAt = Date()
        let revised = try await store.saveContent(revision); XCTAssertTrue(revised)
        let combined = try await store.content(session.id)
        XCTAssertEqual(combined?.outline, [node]); XCTAssertEqual(combined?.corrected.count, 1)
        XCTAssertEqual(combined?.hasOutdatedStudy([row]), true)
        let (_, _, newer) = try await store.beginStudy(session.id); XCTAssertNotEqual(token, newer)
        let old = try await store.finishStudy(session.id, request: token, state: .completed); XCTAssertFalse(old)
    }
    func testRetryResponsesCountSeparatelyWithout250kCap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "FINN2003")
        try await store.save(session)
        let entry = UsageEntry(scope: .conversation, model: "fixture")
        try await store.reserveUsage(entry, session: session.id)
        for id in ["first", "second", "second"] {
            try await store.finishUsage(entry, metadata: APIResponseMetadata(["id": id, "usage": ["input_tokens": 10, "output_tokens": 20, "total_tokens": 30]]), session: session.id)
        }
        try await store.reserveUsage(UsageEntry(scope: .postLesson, model: "fixture", reserved: 300_000), session: session.id)
        let totals = try await store.usageTotals(session.id)
        XCTAssertEqual(totals.conversation, 60); XCTAssertEqual(totals.unknown, 1)
    }
    func testAudioCleanupKeepsConversationAndSessionDeletionFencesLateWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        var session = LectureSession(course: "ECON1111"); session.state = .stopped
        try await store.save(session)
        let turn = try await store.beginConversation(session.id, question: "A general question.")
        _ = try await store.clearAudio(session.id)
        let kept = try await store.conversation(session.id); XCTAssertEqual(kept.count, 2)
        try await store.deleteSession(session.id)
        do {
            _ = try await store.updateConversation(session.id, message: turn.message.id, request: turn.message.requestID!, text: "Late", state: "completed")
            XCTFail("Deleted session must reject late writes")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(session.id).path))
    }
}

private final class ResponseFixtureProtocol: URLProtocol {
    enum Scenario { case revision, failedConversationRetry, completedConversationRetry }
    static var bodies: [[String: Any]] = []
    static var scenario: Scenario = .revision
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        Self.bodies.append(body)
        let first = Self.bodies.count == 1
        if !first, Self.scenario == .failedConversationRetry {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"error\":{\"message\":\"fixture retry failure\"}}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let value = Self.scenario == .revision ? "{\"english\":\"It is six.\",\"chinese\":\"是六。\",\"memory\":[]}" : "重试后的完整回答"
        var response: [String: Any] = ["id": first ? "r1" : "r2", "status": first ? "incomplete" : "completed",
            "usage": ["input_tokens": 10, "output_tokens": 20, "total_tokens": 30]]
        if first { response["incomplete_details"] = ["reason": "max_output_tokens"] }
        else { response["output"] = [["type": "message", "content": [["type": "output_text", "text": value]]]] }
        let event: [String: Any] = ["type": first ? "response.incomplete" : "response.completed", "response": response]
        let data = try! JSONSerialization.data(withJSONObject: event)
        var stream = Data()
        if Self.scenario != .revision {
            let delta: [String: Any] = ["type": "response.output_text.delta", "delta": first ? "已收到的部分回答" : value]
            let bytes = try! JSONSerialization.data(withJSONObject: delta)
            stream.append(Data(("data: " + String(decoding: bytes, as: UTF8.self) + "\n\n").utf8))
        }
        stream.append(Data(("data: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stream); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ConversationRetryProbe {
    private var text = ""
    private var resets = 0
    func append(_ part: String) { text += part }
    func reset() { text = ""; resets += 1 }
    func snapshot() -> (String, Int) { (text, resets) }
}

final class RequestPolicy119Tests: XCTestCase {
    func testRealRequestEncodingUsesMediumAndExpandsIncompleteOutputOnce() async throws {
        ResponseFixtureProtocol.bodies = []; ResponseFixtureProtocol.scenario = .revision
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ResponseFixtureProtocol.self]
        let api = Translator(session: URLSession(configuration: configuration))
        let result = try await api.reviseAndTranslate(TranscriptSegment(start: 0, end: 2, english: "It is five."), course: "ECON1111",
            config: .init(mock: false, model: "gpt-5.6-luna", key: "fixture"), context: "The lecturer corrected the number to six.", usage: nil, delta: { _ in })
        XCTAssertEqual(try LiveRevision.unpack(result)?.english, "It is six.")
        XCTAssertEqual(ResponseFixtureProtocol.bodies.count, 2)
        for body in ResponseFixtureProtocol.bodies {
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "medium")
            XCTAssertEqual(body["store"] as? Bool, false)
        }
        XCTAssertEqual(ResponseFixtureProtocol.bodies[0]["max_output_tokens"] as? Int, 8192)
        XCTAssertEqual(ResponseFixtureProtocol.bodies[1]["max_output_tokens"] as? Int, 16_384)
    }
    func testFailedConversationRetryPreservesTheFirstPartialAnswer() async throws {
        ResponseFixtureProtocol.bodies = []; ResponseFixtureProtocol.scenario = .failedConversationRetry
        defer { ResponseFixtureProtocol.scenario = .revision }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ResponseFixtureProtocol.self]
        let api = Translator(session: URLSession(configuration: configuration)), probe = ConversationRetryProbe()
        do {
            _ = try await api.converse("fixture", config: .init(mock: false, model: "gpt-5.6-luna", key: "fixture"),
                reset: { await probe.reset() }, delta: { await probe.append($0) })
            XCTFail("The retry should fail")
        } catch { XCTAssertEqual((error as? APIError)?.status, 400) }
        let (text, resets) = await probe.snapshot()
        XCTAssertEqual(text, "已收到的部分回答"); XCTAssertEqual(resets, 0)
        XCTAssertEqual(ResponseFixtureProtocol.bodies.count, 2)
    }
    func testCompletedConversationRetryReturnsOneReplacementWithoutStreamingIt() async throws {
        ResponseFixtureProtocol.bodies = []; ResponseFixtureProtocol.scenario = .completedConversationRetry
        defer { ResponseFixtureProtocol.scenario = .revision }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ResponseFixtureProtocol.self]
        let api = Translator(session: URLSession(configuration: configuration)), probe = ConversationRetryProbe()
        let answer = try await api.converse("fixture", config: .init(mock: false, model: "gpt-5.6-luna", key: "fixture"),
            reset: { await probe.reset() }, delta: { await probe.append($0) })
        let (text, resets) = await probe.snapshot()
        XCTAssertEqual(answer, "重试后的完整回答")
        XCTAssertEqual(text, "已收到的部分回答"); XCTAssertEqual(resets, 0)
        XCTAssertEqual(ResponseFixtureProtocol.bodies.count, 2)
    }
}
