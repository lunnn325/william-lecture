import Foundation

public enum CaptionSize: String, CaseIterable, Sendable {
    case small, standard, large
    public var label: String { switch self { case .small: return "小"; case .standard: return "默认"; case .large: return "大" } }
    public var englishPoints: Double { switch self { case .small: return 15; case .standard: return 17; case .large: return 20 } }
    public var chinesePoints: Double { switch self { case .small: return 19; case .standard: return 22; case .large: return 26 } }
}
public enum CaptionTone: String, CaseIterable, Sendable {
    case light, standard, dark
    public var label: String { switch self { case .light: return "浅"; case .standard: return "默认"; case .dark: return "深" } }
    public var opacity: Double { switch self { case .light: return 0.52; case .standard: return 0.72; case .dark: return 0.95 } }
}
