import Foundation

/// Exact standalone fragments only; never classify words inside a sentence.
public enum ShortUtterance {
    private static func word(_ text: String) -> String {
        CaptionSource.normalized(text).lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
    public static func localOnly(_ text: String) -> Bool {
        word(text) == "can" || draft(text) != nil
    }
    /// Conservative local drafts. Ambiguous `can` is left to the installed translator.
    public static func draft(_ text: String, context: String = "") -> String? {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        switch word(text) {
        case "uh", "um", "erm": return question ? "呃？" : "呃"
        case "hmm": return question ? "嗯？" : "嗯"
        case "okay", "ok": return question ? "好吗？" : "好"
        case "yeah", "yep": return question ? "是吗？" : "嗯"
        case "right":
            let previous = context.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if previous.range(of: #"\b(?:turn|go|move|look)(?:\s+to)?(?:\s+the)?[.,:;!?\s]*$"#, options: .regularExpression) != nil { return question ? "右边？" : "右边" }
            return question ? "对吗？" : "对"
        case "what": return question ? "什么？" : "什么"
        case "why": return question ? "为什么？" : "为什么"
        case "really": return question ? "真的吗？" : "真的"
        case "yes": return question ? "是吗？" : "是"
        case "no", "nope": return question ? "不是吗？" : "不"
        case "sure": return question ? "确定吗？" : "当然"
        case "well", "er": return question ? "嗯？" : "嗯"
        case "oh", "ah": return question ? "哦？" : "哦"
        case "huh": return "嗯？"
        case "wow": return "哇"
        case "so": return question ? "所以呢？" : "那么"
        case "all right", "alright", "okay then": return question ? "好吗？" : "好"
        case "exactly": return "正是如此"
        case "absolutely": return "当然"
        case "indeed": return "确实"
        case "of course": return "当然"
        case "you know": return "你知道"
        case "i mean": return "我是说"
        case "thanks", "thank you": return "谢谢"
        case "sorry": return "抱歉"
        case "excuse me": return question ? "什么？" : "打扰一下"
        case "go on": return "继续"
        default: return nil
        }
    }
}
