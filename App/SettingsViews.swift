import SwiftUI
import Translation
import WLCore

struct LectureSettingsView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dismiss) private var dismiss
    var inSheet = false
    @State private var key = ""
    @State private var keySaved = false
    @State private var removeKey = false
    @State private var error = ""
    @State private var preparation: TranslationSession.Configuration?
    @State private var preparing = false
    @State private var preparingSpeech = false
    var body: some View {
        Form {
            if controller.active { Section { Text("正在录课。翻译和课程配置会锁定到这节课结束；你仍可查看诊断。").font(.footnote).foregroundStyle(Color.williamSecondary) } }
            Section("课程") {
                NavigationLink { CoursePickerView(inSheet: false) } label: { LabeledContent("当前课程", value: controller.course) }
                    .disabled(controller.active || controller.busy)
                Picker("英文口音", selection: $controller.locale) {
                    Text("澳洲英语").tag("en-AU"); Text("美式英语").tag("en-US"); Text("英式英语").tag("en-GB")
                }.disabled(controller.active || controller.busy)
            }
            Section("本机中文") {
                Toggle("本机中文快显", isOn: $controller.localEnabled).disabled(controller.active || controller.busy)
                Text(controller.localStatus).font(.footnote).foregroundStyle(Color.williamSecondary).fixedSize(horizontal: false, vertical: true)
                Button("检查语言模型") { Task { await controller.checkLocalModels() } }.disabled(preparing || controller.active || controller.busy)
                Button("准备英文与简体中文模型") {
                    guard !controller.active else { return }
                    preparing = true; controller.localStatus = "正在准备，请完成系统提示"
                    if preparation == nil { preparation = AppleLocalTranslator.preparationConfiguration() }
                    else { preparation?.invalidate() }
                }.disabled(preparing || controller.active || controller.busy || controller.mode == .mock)
                if preparing {
                    ProgressView("准备语言模型…")
                    Button("取消准备") { preparation = nil; preparing = false; controller.localStatus = "准备已取消，可稍后重试" }
                }
                Text("录课前准备一次。录课时不会下载翻译模型；本机不可用时仍保留录音和 GPT 路径。").font(.footnote).foregroundStyle(Color.williamSecondary)
            }
            Section("英文转写") {
                Text(controller.speechStatus).font(.footnote).foregroundStyle(Color.williamSecondary)
                Button("准备英文模型") { Task { preparingSpeech = true; await controller.prepareSpeechModels(); preparingSpeech = false } }
                    .disabled(preparingSpeech || controller.active || controller.busy)
            }
            Section("字幕小窗") {
                Toggle("字幕小窗", isOn: $controller.pictureInPictureEnabled).accessibilityIdentifier("caption-pip-setting")
                PictureInPictureStatus(coordinator: controller.pictureInPicture)
                Text("录课时显示最新英中字幕，切换 App 后使用系统画中画。锁屏时小窗不可见，录音与翻译继续处理。")
                    .font(.footnote).foregroundStyle(Color.williamSecondary)
            }
            Section {
                NavigationLink("字幕显示") {
                    Form { CaptionAppearanceSettings() }.navigationTitle("字幕显示").navigationBarTitleDisplayMode(.inline)
                }.accessibilityIdentifier("caption-display-settings")
            }
            Section("OpenAI 最终翻译") {
                Text(keySaved || Keychain.load() != nil ? "API Key 已保存在本机" : "尚未配置 API Key")
                SecureField("输入新 Key，留空保留原 Key", text: $key, prompt: Text("输入新 Key，留空保留原 Key").foregroundStyle(Color.williamSecondary))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(controller.active || controller.busy)
                TextField("模型名称", text: $controller.model, prompt: Text("模型名称").foregroundStyle(Color.williamSecondary))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(controller.active || controller.busy)
                LabeledContent("摘要与思维导图", value: "gpt-6.1-sol")
                Button("保存设置") { save() }.disabled(controller.active || controller.busy || preparing || controller.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if Keychain.load() != nil { Button("移除 API Key", role: .destructive) { removeKey = true }.disabled(controller.active || controller.busy) }
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(Color.williamWarning) }
                Text("稳定英文和课后文字用于翻译、修订与摘要，原始音频留在本机。Key 保存在 Keychain。").font(.footnote).foregroundStyle(Color.williamSecondary)
            }
            Section {
                NavigationLink { DiagnosticsView() } label: { Label("状态与诊断", systemImage: "stethoscope") }
                Text("William Lecture \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")\n记录保存在本机。").font(.footnote).foregroundStyle(Color.williamSecondary)
            }
        }.navigationTitle("设置").navigationBarTitleDisplayMode(inSheet ? .inline : .large)
            .toolbar { if inSheet { ToolbarItem(placement: .confirmationAction) { Button("完成") { if controller.active || controller.busy { dismiss() } else { save(); if error.isEmpty { dismiss() } } }.disabled(preparing) } } }
            .task { if !controller.active { await controller.checkLocalModels() } }
            .onChange(of: controller.localEnabled) { _, _ in if !controller.active && !controller.busy { controller.saveSettings(key: nil) } }
            .onChange(of: controller.locale) { _, _ in if !controller.active && !controller.busy { controller.saveSettings(key: nil) } }
            .onDisappear {
                key = ""
                if !controller.active && !controller.busy && !controller.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { controller.saveSettings(key: nil) }
            }
            .interactiveDismissDisabled(preparing || !key.isEmpty)
            .alert("移除本机 API Key？", isPresented: $removeKey) {
                Button("取消", role: .cancel) {}
                Button("移除", role: .destructive) { if controller.saveSettings(key: "") { keySaved = false } }
            } message: { Text("已有课堂不会删除。本机翻译仍可使用。") }
            .translationTask(preparation) { session in
                guard !controller.active else { preparing = false; return }
                do { try await session.prepareTranslation(); if await session.isReady { await controller.checkLocalModels() } }
                catch { controller.localStatus = "模型准备未完成：\(error.localizedDescription)" }
                preparing = false
            }
    }
    private func save() {
        guard !controller.active else { error = "请结束录课后再修改。"; return }
        controller.model = controller.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !controller.model.isEmpty else { error = "请填写模型名称。"; return }
        let replacement = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if controller.saveSettings(key: replacement.isEmpty ? nil : replacement) {
            keySaved = Keychain.load() != nil; key = ""; error = ""
        } else { error = controller.warning }
    }
}

private struct PictureInPictureStatus: View {
    @ObservedObject var coordinator: CaptionPictureInPicture
    var body: some View { Text(coordinator.status).font(.footnote).foregroundStyle(Color.williamSecondary) }
}

struct CoursePickerView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dismiss) private var dismiss
    var inSheet = true
    @State private var name = ""
    var body: some View {
        if inSheet { NavigationStack { contents.toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } } } }
        else { contents }
    }
    private var contents: some View {
        Form {
            Section("你的课程") {
                ForEach(controller.courseChoices, id: \.self) { course in
                    Button {
                        controller.selectCourse(course); if inSheet { dismiss() }
                    } label: {
                        HStack { Text(course).foregroundStyle(.primary); Spacer(); if controller.course == course { Image(systemName: "checkmark").foregroundStyle(.tint) } }
                    }.disabled(controller.active || controller.busy)
                }
            }
            Section("添加课程") {
                TextField("例如 ECON1111 · 微观经济学", text: $name, prompt: Text("例如 ECON1111 · 微观经济学").foregroundStyle(Color.williamSecondary))
                    .disabled(controller.active || controller.busy).accessibilityIdentifier("new-course-name")
                Button("添加并选择") {
                    controller.selectCourse(name); name = ""; if inSheet { dismiss() }
                }.disabled(controller.active || controller.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.navigationTitle("选择课程").navigationBarTitleDisplayMode(.inline)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("当前链路") {
                LabeledContent("录音", value: controller.audioStatus)
                LabeledContent("英文", value: controller.speechStatus)
                LabeledContent("本机中文", value: controller.localStatus)
                LabeledContent("GPT", value: controller.translationStatus)
            }
            if !controller.warning.isEmpty || !controller.speechError.isEmpty {
                Section("需要处理") {
                    if !controller.warning.isEmpty { Text(controller.warning).textSelection(.enabled) }
                    if !controller.speechError.isEmpty { Text(controller.speechError).textSelection(.enabled) }
                }
            }
            Section("恢复操作") {
                Button("重试英文转写") { Task { await controller.retrySpeech() } }.disabled(!controller.recording || controller.busy)
                if let session = controller.session {
                    Button("补全 / 重试翻译") { Task { await controller.retryTranslations(session) } }.disabled(controller.busy)
                    Button("取消 GPT 请求") { controller.cancelTranslations() }
                }
                Text("Speech 和翻译的故障不会主动停止录音。录音本身出现错误时，请检查空间或系统中断后再恢复。").font(.footnote).foregroundStyle(Color.williamSecondary)
            }
            Section("诊断与测试") {
                Text(String(format: "收音平均 %.1f dBFS · 峰值 %.1f dBFS", controller.inputRMSDBFS, controller.inputPeakDBFS)).font(.footnote)
                Picker("翻译模式", selection: $controller.mode) { Text("正常翻译").tag(TranslationMode.openAI); Text("演示 / 模拟").tag(TranslationMode.mock) }.disabled(controller.active || controller.busy)
                    .onChange(of: controller.mode) { _, _ in if !controller.active && !controller.busy { controller.saveSettings(key: nil) } }
                Text("演示译文有明确标识。诊断文件可从课程详情导出，用于区分转写、缓冲和翻译延迟。").font(.footnote).foregroundStyle(Color.williamSecondary)
            }
        }.navigationTitle("状态与诊断").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
