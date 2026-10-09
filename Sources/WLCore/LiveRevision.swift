import Foundation

/// One atomic English/Chinese upgrade, bound to the unchanged original source revision.
public struct LiveRevision: Codable, Sendable, Equatable {
    public var english: String
    public var chinese: String
    public var evidence: [String]
    public init(english: String, chinese: String, evidence: [String] = []) {
        self.english = english; self.chinese = chinese; self.evidence = evidence
    }
    private static let prefix = "__WL_LIVE_REVISION__:"
    public func encoded() throws -> String { Self.prefix + String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    public static func unpack(_ text: String) throws -> LiveRevision? {
        guard text.hasPrefix(prefix) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(text.dropFirst(prefix.count).utf8))
    }
    public func validated(source: String, context: String) throws -> Self {
        let value = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= max(160, source.count * 2),
              LessonAPI.protectedTokens(source) == LessonAPI.protectedTokens(value),
              symbols(source) == symbols(value) else { throw TranslationResponseFailure.incomplete }
        let originalWords = words(source), revisedWords = words(value)
        if originalWords != revisedWords {
            let cited = evidence.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let citedWords = Set(cited.flatMap(words))
            let added = Set(revisedWords).subtracting(Set(originalWords))
            let grammar: Set<String> = ["the", "a", "an", "is", "are", "was", "were", "of", "to", "in", "on", "and"]
            guard !cited.isEmpty, cited.count <= 4,
                  cited.allSatisfy({ context.localizedCaseInsensitiveContains($0) }),
                  added.subtracting(grammar).isSubset(of: citedWords),
                  originalWords.count <= 3 || Set(originalWords).intersection(Set(revisedWords)).count * 2 >= Set(originalWords).count else {
                throw TranslationResponseFailure.incomplete
            }
        }
        return Self(english: value, chinese: chinese.trimmingCharacters(in: .whitespacesAndNewlines), evidence: evidence)
    }
    private func words(_ text: String) -> [String] { text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
    private func symbols(_ text: String) -> String { String(text.filter { "=<>%$£€¥".contains($0) }) }
    /// Extract only complete escaped characters; never display streamed JSON as subtitles.
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
