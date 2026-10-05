import AVFoundation
import SwiftUI
import WLCore

struct ValidationView: View {
    @EnvironmentObject private var controller: LectureController
    @State private var settings = false
    var body: some View {
        NavigationStack {
            List {
                Section("V0 · 技术验证") {
                    TextField("课程名称", text: $controller.course).disabled(controller.active)
                    Text(SessionStore.timestamp(controller.elapsed)).font(.system(.title, design: .monospaced))
                    HStack {
                        Button("开始") { Task { await controller.start() } }.disabled(controller.active || controller.busy)
                        Spacer()
                        Button(controller.recording ? "暂停" : "恢复") { Task { await controller.pauseOrResume() } }.disabled(!controller.active || controller.busy)
                        Spacer()
                        Button("停止", role: .destructive) { Task { await controller.stop() } }.disabled(!controller.active || controller.busy)
                    }.buttonStyle(.bordered)
                    if controller.busy { ProgressView("正在处理…") }
                }
                Section("当前字幕") {
                    if controller.mode == .mock { Text("MOCK · 仅测试链路，中文为模拟内容").foregroundStyle(.orange) }
                    Text(controller.currentChinese.isEmpty ? "等待中文…" : controller.currentChinese).font(.title3).textSelection(.enabled)
                    Text(controller.volatileEnglish.isEmpty ? (controller.visible.last?.english ?? "等待英文…") : controller.volatileEnglish)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section("系统状态") {
                    Text("录音：\(controller.audioStatus)")
                    Text("英文：\(controller.speechStatus)")
                    Text("中文：\(controller.translationStatus)")
                    ProgressView(value: min(1, controller.peak)).accessibilityLabel("麦克风峰值")
                    if !controller.warning.isEmpty { Text(controller.warning).foregroundStyle(.red).textSelection(.enabled) }
                    if let session = controller.session {
                        Button("补翻译 / 重试") { Task { await controller.retryTranslations(session) } }
                        Button("取消翻译请求") { controller.cancelTranslations() }
                    }
                }
                if !controller.visible.isEmpty {
                    Section("最近 30 段（完整内容已写盘）") {
                        ForEach(controller.visible) { segment in SegmentRow(segment: segment) }
                    }
                }
                Section("历史课堂") {
                    ForEach(controller.history) { session in
                        NavigationLink {
                            SessionView(session: session).environmentObject(controller)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(session.course)
                                Text("\(session.startedAt.formatted()) · \(session.state.rawValue)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("刷新历史") { Task { await controller.refreshHistory() } }
                }
            }
            .navigationTitle("William Lecture")
            .toolbar { Button("设置") { settings = true }.disabled(controller.active) }
            .sheet(isPresented: $settings) { SettingsView().environmentObject(controller) }
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(SessionStore.timestamp(segment.start)) – \(SessionStore.timestamp(segment.end)) · \(segment.status.rawValue)").font(.caption).foregroundStyle(.secondary)
            Text(segment.chinese ?? "[中文待处理]").textSelection(.enabled)
            Text(segment.english).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if let error = segment.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var replaceKey = false
    var body: some View {
        NavigationStack {
            Form {
                Section("翻译") {
                    Picker("模式", selection: $controller.mode) { Text("模拟翻译").tag(TranslationMode.mock); Text("OpenAI").tag(TranslationMode.openAI) }
                    TextField("模型", text: $controller.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("默认 gpt-4.1-mini，可按你的账户额度更换。免费额度是否可用由账户与模型决定。").font(.caption)
                    Text(Keychain.load() == nil ? "未保存 API Key" : "已在本机 Keychain 保存 Key")
                    Toggle("更新 API Key", isOn: $replaceKey)
                    if replaceKey { SecureField("API Key（留空则删除）", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    Text("Key 不进入源码、导出或诊断。真实翻译会把英文片段发送给 OpenAI。").font(.caption)
                }
                Section("Apple Speech") {
                    Picker("英文 locale", selection: $controller.locale) {
                        Text("澳洲英语").tag("en-AU"); Text("美式英语").tag("en-US"); Text("英式英语").tag("en-GB")
                    }
                    Text("首次使用可能下载系统模型。准备期间继续录音，并标记未实时转写的时段。").font(.caption)
                }
                Section("测试限制") {
                    Text("音频分段保存为 16-bit PCM CAF；48 kHz 单声道约 330 MB/小时，立体声约两倍。强制退出、系统中断、磁盘耗尽可能产生缺口。V0 尚须真机长录验证。")
                }
            }.navigationTitle("测试设置").toolbar {
                Button("保存") { controller.saveSettings(key: replaceKey ? key : nil); key = ""; dismiss() }
            }
        }
    }
}

private struct SessionView: View {
    @EnvironmentObject private var controller: LectureController
    let session: LectureSession
    @State private var segments: [TranscriptSegment] = []
    @State private var page = 0
    @State private var language = ExportLanguage.bilingual
    @State private var markdown = false
    @State private var exportURL: URL?
    @State private var diagnosticsURL: URL?
    @State private var error = ""
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var audioIndex = 0
    @State private var playbackDelegate: PlaybackDelegate?
    var body: some View {
        List {
            Section("本地录音") {
                Text("\(session.audioFiles.count) 个独立音频片段 · \(SessionStore.timestamp(session.duration))")
                if !session.audioFiles.isEmpty {
                    Picker("片段", selection: Binding(get: { audioIndex }, set: { index in
                        player?.stop(); player = nil; playing = false; audioIndex = index
                    })) { ForEach(Array(session.audioFiles.enumerated()), id: \.offset) { index, name in Text(name).tag(index) } }
                    Button(playing ? "暂停回放" : "播放（自动续播下一段）") { togglePlayback() }.disabled(controller.active)
                    ShareLink(item: controller.store.folder(session.id).appendingPathComponent(session.audioFiles[min(audioIndex, session.audioFiles.count - 1)])) { Text("导出此音频片段") }
                }
                Text("全部音频和原始数据可通过 Windows iTunes 文件共享保存 William Lecture 的 Sessions 文件夹。").font(.caption)
            }
            Section("导出文字与诊断") {
                Picker("语言", selection: $language) { Text("双语").tag(ExportLanguage.bilingual); Text("纯英文").tag(ExportLanguage.english); Text("纯中文").tag(ExportLanguage.chinese) }
                Toggle("Markdown（关闭为 UTF-8 TXT）", isOn: $markdown)
                Button("生成导出") { Task {
                    do {
                        exportURL = try await controller.store.export(session.id, language: language, markdown: markdown)
                        let diagnostic = controller.store.folder(session.id).appendingPathComponent("diagnostics.jsonl")
                        if FileManager.default.fileExists(atPath: diagnostic.path) { diagnosticsURL = diagnostic }
                    } catch { self.error = error.localizedDescription }
                } }
                if let exportURL { ShareLink(item: exportURL) { Text("分享文字稿") } }
                if let diagnosticsURL { ShareLink(item: diagnosticsURL) { Text("分享 diagnostics.jsonl") } }
                Button("补翻译 / 重试") { Task { await controller.retryTranslations(session); await load() } }
                Button("刷新文字稿") { Task { await load() } }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            Section("文字稿 · 第 \(page + 1) 页") {
                ForEach(Array(segments.dropFirst(page * 50).prefix(50))) { SegmentRow(segment: $0) }
                HStack {
                    Button("上一页") { page = max(0, page - 1) }.disabled(page == 0)
                    Spacer()
                    Button("下一页") { page += 1 }.disabled((page + 1) * 50 >= segments.count)
                }
            }
        }.navigationTitle(session.course).task { await load() }
            .onDisappear { player?.stop(); player = nil; playing = false }
    }
    private func load() async {
        do { segments = try await controller.store.segments(session.id) } catch { self.error = error.localizedDescription }
    }
    private func togglePlayback() {
        if playing { player?.pause(); playing = false; return }
        if let player, player.currentTime > 0 { player.play(); playing = true; return }
        playChunk()
    }
    private func playChunk() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback); try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(contentsOf: controller.store.folder(session.id).appendingPathComponent(session.audioFiles[audioIndex]))
            let delegate = PlaybackDelegate { success in
                Task { @MainActor in
                    if success && audioIndex + 1 < session.audioFiles.count { audioIndex += 1; playChunk() }
                    else { playing = false; player = nil }
                }
            }
            playbackDelegate = delegate; next.delegate = delegate; player = next; playing = next.play()
        } catch { self.error = error.localizedDescription; playing = false }
    }
}

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    let ended: (Bool) -> Void
    init(ended: @escaping (Bool) -> Void) { self.ended = ended }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { ended(flag) }
}
