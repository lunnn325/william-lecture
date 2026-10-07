import Foundation

/// Exact standalone fragments only; never classify words inside a sentence.
public enum ShortUtterance {
    private static func word(_ text: String) -> String {
        CaptionSource.normalized(text).lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
    public static func localOnly(_ text: String) -> Bool {
        ["can", "uh", "um", "erm", "hmm", "okay", "ok", "yeah", "yep"].contains(word(text))
    }
    /// Conservative local drafts. Ambiguous `can` is left to the installed translator.
    public static func draft(_ text: String) -> String? {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        switch word(text) {
        case "uh", "um", "erm": return question ? "呃？" : "呃"
        case "hmm": return question ? "嗯？" : "嗯"
        case "okay", "ok": return question ? "好吗？" : "好"
        case "yeah", "yep": return question ? "是吗？" : "嗯"
        default: return nil
        }
    }
}
