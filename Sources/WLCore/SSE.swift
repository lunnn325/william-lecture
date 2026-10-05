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

public enum TranslationEvent {
    case delta(String), completed, ignored
    public static func decode(_ json: [String: Any]) throws -> Self {
        switch json["type"] as? String {
        case "response.output_text.delta": return .delta(json["delta"] as? String ?? "")
        case "response.completed": return .completed
        case "response.failed", "response.incomplete", "error", "response.refusal.delta":
            throw WLFailure.message("Translation stream failed or refused (\(json["type"] as? String ?? "error"))")
        default: return .ignored
        }
    }
}
