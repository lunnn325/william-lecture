import Foundation

/// URLSession's line iterator handles UTF-8 boundaries; this parser handles SSE event boundaries.
public struct SSEParser: Sendable {
    private var dataLines: [String] = []
    public init() {}
    public mutating func line(_ line: String) -> [String: Any]? {
        if line.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true) }
            let data = dataLines.joined(separator: "\n").data(using: .utf8) ?? Data()
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5)); if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
            // Responses events are a single JSON data line. This also works with line
            // iterators that omit blank lines; multiline JSON waits for the rest.
            if let object = (try? JSONSerialization.jsonObject(with: Data(dataLines.joined(separator: "\n").utf8))) as? [String: Any] {
                dataLines.removeAll(keepingCapacity: true)
                return object
            }
        }
        return nil
    }
}

public enum TranslationResponseFailure: Error, LocalizedError, Sendable, Equatable {
    case incomplete, refused
    public var errorDescription: String? {
        self == .incomplete ? "翻译响应未完整返回" : "该段翻译未返回可用内容"
    }
}

public enum TranslationEvent {
    case delta(String), textDone(String), completed, ignored
    public static func decode(_ json: [String: Any]) throws -> Self {
        switch json["type"] as? String {
        case "response.output_text.delta": return .delta(json["delta"] as? String ?? "")
        case "response.output_text.done": return .textDone(json["text"] as? String ?? "")
        case "response.completed": return .completed
        case "response.failed", "response.incomplete", "error": throw TranslationResponseFailure.incomplete
        case "response.refusal.delta", "response.refusal.done": throw TranslationResponseFailure.refused
        default: return .ignored
        }
    }
    public static func completedText(_ json: [String: Any]) -> String? {
        guard json["type"] as? String == "response.completed", let response = json["response"] as? [String: Any],
              let output = response["output"] as? [[String: Any]] else { return nil }
        let text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
