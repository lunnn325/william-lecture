import Foundation

public enum DiagnosticRedaction {
    public static func redact(_ text: String) -> String {
        let pattern = #"(?i)\bsk-[A-Za-z0-9_-]{8,}|Bearer\s+[^\s\"',;]+"#
        return text.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
    }
}
