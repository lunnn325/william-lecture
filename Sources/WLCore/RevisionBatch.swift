import Foundation

/// Model-visible identities are local to one immutable request snapshot.
public struct RevisionRow: Codable, Sendable {
    public var id: String
    public var english: String
    public var chinese: String
    public var memory: [LiveMemoryUpdate]?
    public init(id: String, english: String, chinese: String, memory: [LiveMemoryUpdate]? = nil) {
        self.id = id; self.english = english; self.chinese = chinese; self.memory = memory
    }
}

public struct RevisionBatch: Sendable {
    public let sources: [TranscriptSegment]
    public init(_ sources: [TranscriptSegment]) { self.sources = sources }
    public var aliases: [String] { sources.indices.map { "s\($0 + 1)" } }
    public func resolve(_ rows: [RevisionRow]) -> (values: [UUID: LiveRevision], issues: [String]) {
        var values: [UUID: LiveRevision] = [:], issues: [String] = []
        let index = Dictionary(uniqueKeysWithValues: zip(aliases, sources))
        for row in rows {
            guard let source = index[row.id] else { issues.append("unknown:\(row.id)"); continue }
            guard values[source.id] == nil else { issues.append("duplicate:\(row.id)"); continue }
            guard let value = try? LiveRevision(english: row.english, chinese: row.chinese, memory: row.memory)
                .validated(source: source.english, context: "") else { issues.append("empty:\(row.id)"); continue }
            values[source.id] = value
        }
        for (alias, source) in zip(aliases, sources) where values[source.id] == nil { issues.append("missing:\(alias)") }
        return (values, issues)
    }
    public static func rowSchema(aliases: [String]? = nil, memory: Bool = true) -> [String: Any] {
        var fields: [String: Any] = ["english": ["type": "string"], "chinese": ["type": "string"]]
        if let aliases { fields["id"] = ["type": "string", "enum": aliases] }
        if memory {
            fields["memory"] = ["type": "array", "items": ["type": "object", "additionalProperties": false,
                "required": ["kind", "english", "chinese", "quote"], "properties": [
                    "kind": ["type": "string", "enum": ["topic", "term"]], "english": ["type": "string"],
                    "chinese": ["type": "string"], "quote": ["type": "string"]]]]
        }
        return ["type": "object", "additionalProperties": false, "properties": fields, "required": fields.keys.sorted()]
    }
}

public enum APIWorkload: String, Sendable {
    case live, recheck, summary, conversation, lookup
    public var outputTokens: Int { self == .summary || self == .conversation ? 16_384 : (self == .lookup ? 4096 : 8192) }
    public var timeout: Double { self == .summary || self == .conversation ? 300 : 120 }
    public var effort: String { "medium" }
}

public struct ResponseIncomplete: Error, LocalizedError {
    public let reason: String
    public init(_ response: [String: Any]) {
        reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String ??
            (response["error"] as? [String: Any])?["message"] as? String ?? "unknown"
    }
    public var outputLimit: Bool { reason == "max_output_tokens" }
    public var errorDescription: String? { "请求未完整结束：\(reason)" }
}
