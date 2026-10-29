import Foundation

public struct ConversationSource: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var alias: String
    public var offset: Double
}
public struct ConversationMessage: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var role: String
    public var text: String
    public var state: String
    public var requestID: UUID?
    public var question: String?
    public var sources: [ConversationSource]?
    public var snapshotEnd: Double?
    public var error: String?
    public var at = Date()
    public init(role: String, text: String, state: String = "completed") { self.role = role; self.text = text; self.state = state }
}
public struct ConversationTurn: Sendable {
    public var message: ConversationMessage
    public var input: String
}

extension SessionStore {
    public func conversation(_ id: UUID) throws -> [ConversationMessage] {
        try requireSession(id)
        let path = folder(id).appendingPathComponent("conversation.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([ConversationMessage].self, from: Data(contentsOf: path))
    }
    private func writeConversation(_ messages: [ConversationMessage], session id: UUID) throws {
        try requireSession(id)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let path = folder(id).appendingPathComponent("conversation.json")
        try encoder.encode(messages).write(to: path, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path.path)
        #endif
    }
    public func recoverConversation(_ id: UUID) throws -> [ConversationMessage] {
        var messages = try conversation(id)
        for i in messages.indices where messages[i].state == "pending" {
            messages[i].state = "interrupted"; messages[i].error = "生成已中断，可重试"
        }
        try writeConversation(messages, session: id)
        return messages
    }
    public func beginConversation(_ id: UUID, question: String, retry: UUID? = nil) throws -> ConversationTurn {
        var messages = try conversation(id)
        guard !messages.contains(where: { $0.state == "pending" }) else { throw WLFailure.message("已有回答正在生成") }
        var prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let retry, let previous = messages.first(where: { $0.id == retry && $0.role == "assistant" }) {
            prompt = previous.question ?? prompt
        } else if !prompt.isEmpty { messages.append(ConversationMessage(role: "user", text: prompt)) }
        guard !prompt.isEmpty else { throw WLFailure.message("请输入问题") }
        let rows = try segments(id), content = try self.content(id), session = try sessionMetadata(id)
        let refs = rows.enumerated().map { ConversationSource(id: $0.element.id, alias: "s\($0.offset + 1)", offset: $0.element.start) }
        let lecture: [[String: Any]] = zip(refs, rows).map { ref, row in
            ["id": ref.alias, "time": SessionStore.readingTime(ref.offset), "original": row.english,
             "english": content?.correction(for: row)?.english ?? row.displayEnglish,
             "chinese": content?.correction(for: row)?.chinese ?? row.exportChinese ?? "[中文缺失]"]
        }
        let history = messages.filter { $0.role == "user" || ($0.role == "assistant" && $0.state == "completed") }
            .map { ["role": $0.role, "text": $0.text] }
        let data = try JSONSerialization.data(withJSONObject: ["course": CourseProfiles.context(session.course),
            "lecture": lecture, "history": history, "currentQuestion": prompt])
        var answer = ConversationMessage(role: "assistant", text: "", state: "pending")
        answer.question = prompt; answer.requestID = UUID(); answer.sources = refs; answer.snapshotEnd = rows.map(\.end).max() ?? 0
        if let retry, let i = messages.firstIndex(where: { $0.id == retry }) { answer.id = retry; messages[i] = answer }
        else { messages.append(answer) }
        try writeConversation(messages, session: id)
        return ConversationTurn(message: answer, input: String(decoding: data, as: UTF8.self))
    }
    @discardableResult public func updateConversation(_ id: UUID, message: UUID, request: UUID, text: String,
                                                       state: String, error: String? = nil) throws -> Bool {
        var messages = try conversation(id)
        guard let i = messages.firstIndex(where: { $0.id == message }), messages[i].requestID == request,
              messages[i].state == "pending" else { return false }
        messages[i].text = text; messages[i].state = state; messages[i].error = error.map(DiagnosticRedaction.redact)
        try writeConversation(messages, session: id)
        return true
    }
}
