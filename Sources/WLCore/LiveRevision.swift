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
    public func validated(source: String, context: String) throws -> Self {
        let value = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= max(160, source.count * 2) else { throw LiveRevisionRejection("invalid_pair") }
        guard LessonAPI.protectedTokens(source) == LessonAPI.protectedTokens(value), symbols(source) == symbols(value),
              codeTokens(source) == codeTokens(value) else { throw LiveRevisionRejection("protected_content_changed") }
        let originalWords = words(source), revisedWords = words(value)
        if originalWords != revisedWords {
            let cited = evidence.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let added = Set(revisedWords).subtracting(Set(originalWords))
            let removed = Set(originalWords).subtracting(Set(revisedWords))
            let grammar: Set<String> = ["the", "a", "an", "is", "are", "was", "were", "of", "to", "in", "on", "and", "at", "it", "that", "this"]
            let data = source + "\n" + context
            guard !cited.isEmpty, cited.count <= 4, cited.allSatisfy({ !$0.isEmpty && data.localizedCaseInsensitiveContains($0) })
            else { throw LiveRevisionRejection("invalid_evidence") }
            let localChanges = max(1, min(4, originalWords.count / 3))
            guard added.subtracting(grammar).count <= localChanges, removed.subtracting(grammar).count <= localChanges,
                  originalWords.count <= 3 || Set(originalWords).intersection(Set(revisedWords)).count * 2 >= Set(originalWords).count
            else { throw LiveRevisionRejection("unsupported_rewrite") }
            // A correction need not already occur verbatim in a quoted excerpt. Small
            // near-form errors can use the target phrase itself; larger substitutions
            // still need the replacement term in actual context/course vocabulary.
            let contextWords = Set(words(context))
            guard added.subtracting(grammar).allSatisfy({ new in
                contextWords.contains(new) || removed.contains(where: { nearForm($0, new) })
            }) else { throw LiveRevisionRejection("unsupported_lexical_change") }
        }
        return Self(english: value, chinese: chinese.trimmingCharacters(in: .whitespacesAndNewlines), evidence: evidence, memory: memory)
    }
    private func words(_ text: String) -> [String] { text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
    private func symbols(_ text: String) -> String { String(text.filter { "=<>%$£€¥+-−*/^".contains($0) }) }
    private func codeTokens(_ text: String) -> [String] {
        var pattern = #"`[^`]+`|\b[A-Z]{2,}[A-Za-z0-9_]*\b|\b[A-Za-z_][A-Za-z0-9_]*[._][A-Za-z0-9_.]+\b|\b(?:kg|mg|km|cm|mm|bps|Hz|kWh|mL|ms)\b"#
        if text.range(of: #"[=<>+*/]|\b(?:variable|coefficient|matrix|vector|denote|equals|formula)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            pattern += #"|\b[A-Z]\b"#
        }
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    private func nearForm(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if [lhs + "s", lhs + "es", lhs + "ed", lhs + "ing"].contains(rhs) ||
            [rhs + "s", rhs + "es", rhs + "ed", rhs + "ing"].contains(lhs) { return true }
        let a = Array(lhs), b = Array(rhs), limit = min(a.count, b.count) < 5 ? 1 : 2
        guard abs(a.count - b.count) <= limit else { return false }
        var row = Array(0...b.count)
        for (i, letter) in a.enumerated() {
            var next = [i + 1]
            for (j, other) in b.enumerated() { next.append(min(min(next[j] + 1, row[j + 1] + 1), row[j] + (letter == other ? 0 : 1))) }
            row = next
        }
        return row[b.count] <= limit
    }
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
