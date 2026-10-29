import Foundation

/// One atomic English/Chinese upgrade, bound to the unchanged original source revision.
public struct LiveRevision: Codable, Sendable, Equatable {
    public var english: String
    public var chinese: String
    public var evidence: [String]
    public var memory: [LiveMemoryUpdate]?
    public init(english: String, chinese: String, evidence: [String] = [], memory: [LiveMemoryUpdate]? = nil) {
        self.english = english; self.chinese = chinese; self.evidence = evidence; self.memory = memory
    }
    private static let prefix = "__WL_LIVE_REVISION__:"
    public func encoded() throws -> String { Self.prefix + String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    public static func unpack(_ text: String) throws -> LiveRevision? {
        guard text.hasPrefix(prefix) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(text.dropFirst(prefix.count).utf8))
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        english = try c.decode(String.self, forKey: .english)
        chinese = try c.decode(String.self, forKey: .chinese)
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        memory = try c.decodeIfPresent([LiveMemoryUpdate].self, forKey: .memory)
    }
    public func validated(source: String, context: String) throws -> Self {
        let value = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !translated.isEmpty else { throw LiveRevisionRejection("invalid_pair") }
        return Self(english: value, chinese: translated, evidence: evidence, memory: memory)
    }
    public static func streamedChinese(_ json: String) -> String? {
        guard let range = json.range(of: #""chinese"\s*:\s*""#, options: .regularExpression) else { return nil }
        var raw = "", escaped = false
        for character in json[range.upperBound...] {
            if character == "\"", !escaped { break }
            raw.append(character)
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        if escaped { raw.removeLast() }
        if let slash = raw.range(of: #"\\u[0-9a-fA-F]{0,3}$"#, options: .regularExpression) { raw.removeSubrange(slash) }
        return try? JSONDecoder().decode(String.self, from: Data(("\"" + raw + "\"").utf8))
    }
}
