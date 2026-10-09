import SwiftUI
import WLCore

struct CaptionAppearanceSettings: View {
    @AppStorage("captionChineseSize") private var chineseSize = CaptionSize.standard
    @AppStorage("captionEnglishSize") private var englishSize = CaptionSize.standard
    @AppStorage("captionChineseTone") private var chineseTone = CaptionTone.dark
    @AppStorage("captionEnglishTone") private var englishTone = CaptionTone.standard
    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    var body: some View {
        Section("字幕显示") {
            Picker("中文字号", selection: $chineseSize) { ForEach(CaptionSize.allCases, id: \.self) { Text($0.label).tag($0) } }
                .accessibilityIdentifier("caption-chinese-size-setting")
            Picker("中文深浅", selection: $chineseTone) { ForEach(CaptionTone.allCases, id: \.self) { Text($0.label).tag($0) } }
            Picker("英文字号", selection: $englishSize) { ForEach(CaptionSize.allCases, id: \.self) { Text($0.label).tag($0) } }
                .accessibilityIdentifier("caption-english-size-setting")
            Picker("英文深浅", selection: $englishTone) { ForEach(CaptionTone.allCases, id: \.self) { Text($0.label).tag($0) } }
            VStack(alignment: .leading, spacing: 10) {
                Text("The marginal benefit is not the same as the total benefit.")
                    .font(.system(size: englishSize.englishPoints * scale)).foregroundStyle(Color.primary.opacity(englishTone.opacity)).lineSpacing(4)
                Text("边际收益和总收益并不相同。")
                    .font(.system(size: chineseSize.chinesePoints * scale)).foregroundStyle(Color.primary.opacity(chineseTone.opacity)).lineSpacing(6)
            }.padding(.vertical, 8).accessibilityIdentifier("caption-appearance-preview")
            Button("恢复默认显示") { chineseSize = .standard; englishSize = .standard; chineseTone = .dark; englishTone = .standard }
        }
    }
}
