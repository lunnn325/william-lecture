import SwiftUI
import UIKit
import WLCore

struct WorkspaceCaption: Identifiable, Equatable {
    let id: UUID
    let start: Double
    let english: String
    let chinese: String?
    var provisional = false
    init(_ segment: TranscriptSegment, chinese: String? = nil) {
        id = segment.id; start = segment.start; english = segment.english; self.chinese = chinese ?? segment.displayChinese
    }
    init(id: UUID, start: Double, english: String, chinese: String?, provisional: Bool) {
        self.id = id; self.start = start; self.english = english; self.chinese = chinese; self.provisional = provisional
    }
}
struct NoteContext: Identifiable {
    let sessionID: UUID
    let note: LectureNote
    var id: UUID { note.id }
}

struct LectureRootView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.scenePhase) private var phase
    var body: some View {
        TabView {
            WorkspaceView().tabItem { Label("录课", systemImage: "waveform") }
            HistoryView().tabItem { Label("记录", systemImage: "clock") }
            NavigationStack { LectureSettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(.teal)
        .onChange(of: phase) { _, phase in controller.setForeground(phase == .active) }
    }
}

struct CaptionTextView: View {
    let caption: WorkspaceCaption
    var marked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(caption.english).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if marked { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.tint).accessibilityLabel("已标记") }
            }
            Text(caption.chinese ?? "中文稍后出现…")
                .font(.title2.weight(.medium)).lineSpacing(5)
                .foregroundStyle(caption.chinese == nil ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(SessionStore.timestamp(caption.start)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("caption-\(caption.id.uuidString)")
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var feed = CaptionFeed()
    @State private var nearBottom = true
    @State private var settings = false
    @State private var status = false
    @State private var courses = false
    @State private var confirmStop = false
    @State private var noteContext: NoteContext?
    @State private var savedDetail = false
    @State private var loadingEarlier = false
    @State private var hasEarlier = false
    @State private var paneSessionID: UUID?
    private var live: WorkspaceCaption? { feed.following ? controller.workspaceDraft : nil }
    private var bottomID: UUID? { live?.id ?? feed.rows.last?.id }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if feed.rows.isEmpty && live == nil { emptyState }
                        if hasEarlier {
                            Button(loadingEarlier ? "正在读取…" : "查看更早字幕") { Task { await earlier() } }
                                .font(.subheadline).frame(minHeight: 44).disabled(loadingEarlier)
                        }
                        ForEach(feed.rows) { segment in
                            let caption = WorkspaceCaption(segment, chinese: controller.captionChinese(segment))
                            captionRow(caption)
                        }
                        if let live { captionRow(live) }
                        Color.clear.frame(height: 8).id("caption-bottom")
                    }
                    .frame(maxWidth: 760).padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("caption-scroll")
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height + geometry.contentInsets.bottom - 80
                } action: { _, value in nearBottom = value }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { feed.suspend() }
                    if phase == .idle && nearBottom && !feed.following {
                        Task { await latest(proxy) }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !feed.following {
                        Button { Task { await latest(proxy) } } label: {
                            Label(feed.hasNewContent ? "有新字幕 · 回到最新" : "回到最新", systemImage: "arrow.down")
                                .font(.subheadline.weight(.medium)).padding(.horizontal, 16).frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .padding(.trailing, 22).padding(.bottom, 12).accessibilityIdentifier("follow-latest")
                    }
                }
                .onChange(of: controller.latestCaptionUpdate) { _, segment in
                    if let segment { feed.merge([segment]); follow(proxy) }
                }
                .onChange(of: controller.visible) { _, segments in feed.merge(segments); follow(proxy) }
                .onChange(of: controller.workspaceDraft) { _, _ in follow(proxy) }
                .task(id: controller.session?.id) {
                    let id = controller.session?.id
                    let rows = await controller.latestWorkspaceRows()
                    guard controller.session?.id == id else { return }
                    if paneSessionID != id { paneSessionID = id; feed = CaptionFeed() }
                    feed.resume(latest: rows); hasEarlier = (rows.first?.start ?? 0) > 0.1; follow(proxy)
                }
                .transaction { $0.animation = nil }
                .safeAreaInset(edge: .top, spacing: 0) { compactStatus }
                .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(controller.active ? controller.course : "William Lecture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { courses = true } label: {
                        VStack(spacing: 3) {
                            HStack(spacing: 4) {
                                Text(controller.course).font(.headline).lineLimit(1)
                                if !controller.active { Image(systemName: "chevron.down").font(.caption2) }
                            }
                            Text("英语 → 中文").font(.caption).foregroundStyle(.secondary)
                        }.foregroundStyle(.primary).frame(minHeight: 44)
                    }.disabled(controller.active || controller.busy).accessibilityLabel("选择课程，\(controller.course)").accessibilityIdentifier("course-picker")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("录课设置").frame(minWidth: 44, minHeight: 44)
                }
            }
            .toolbar(controller.active ? .hidden : .visible, for: .tabBar)
            .sheet(isPresented: $settings) { NavigationStack { LectureSettingsView(inSheet: true) } }
            .sheet(isPresented: $status) { NavigationStack { DiagnosticsView() } }
            .sheet(isPresented: $courses) { CoursePickerView() }
            .sheet(item: $noteContext) { NoteEditorView(context: $0) }
            .sheet(isPresented: $savedDetail) {
                if let session = controller.session { NavigationStack { LessonDetailView(session: session, inSheet: true) } }
            }
            .alert("结束这节课？", isPresented: $confirmStop) {
                Button("继续录课", role: .cancel) {}
                Button("结束并保存") { Task { await controller.stop() } }
            } message: { Text("已经录下的音频和文字会保存在「记录」中。") }
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(controller.active ? "正在听课堂…" : "把注意力留给课堂。")
                .font(.title2.weight(.medium))
            Text(controller.active ? "英文会先出现，中文随后跟上。\n录音独立保存在这台设备。" : "选择课程，开始录音。\n没听清时，低头看一眼中文。")
                .font(.body).foregroundStyle(.secondary).lineSpacing(5)
            if !controller.active {
                Button("选择课程") { courses = true }.frame(minHeight: 44)
                Text("轻点一句可标记，双击可写笔记。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.top, 64).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var compactStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { status = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: controller.localEnabled ? "iphone" : "text.bubble")
                    Text(localSummary)
                    Text("·")
                    Text(gptSummary)
                    Spacer(minLength: 4)
                    Image(systemName: "info.circle")
                }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
            }.accessibilityLabel("翻译状态与诊断")
            if !controller.warning.isEmpty {
                Button("保存或录音遇到问题 · 查看详情") { status = true }
                    .font(.footnote).foregroundStyle(.orange).frame(minHeight: 44).accessibilityIdentifier("system-warning")
            } else if !controller.speechError.isEmpty {
                Button("英文暂时不可用 · 点按重试") { Task { await controller.retrySpeech() } }
                    .font(.footnote).foregroundStyle(.orange).frame(minHeight: 44)
            } else if controller.mode == .mock {
                Text("演示内容，不代表真实翻译。请在设置中启用 OpenAI。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 22).padding(.bottom, 6).background(.background)
    }
    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(controller.recording ? Color.teal : Color.secondary).frame(width: 6, height: 6)
                Text(recordingState).font(.subheadline)
                Spacer()
                Text(SessionStore.timestamp(controller.elapsed)).font(.system(.callout, design: .monospaced)).monospacedDigit()
                    .accessibilityIdentifier("recording-time")
            }
            if controller.active {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { pauseButton; stopButton; noteButton }
                    VStack(spacing: 8) { HStack(spacing: 12) { pauseButton; stopButton }; noteButton }
                }
            } else {
                if controller.session != nil {
                    Button("查看这节课") { savedDetail = true }.font(.subheadline).frame(minHeight: 44)
                }
                Button { Task { await controller.start() } } label: {
                    Label(controller.busy ? "正在准备…" : "开始录音", systemImage: "mic.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(controller.busy)
                    .accessibilityIdentifier("start-recording")
            }
        }.frame(maxWidth: 760).padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 12)
            .frame(maxWidth: .infinity).background(.bar)
    }
    private var localSummary: String {
        if !controller.localEnabled { return "本机已关闭" }
        if controller.localStatus.contains("未准备") || controller.localStatus.contains("需要准备") { return "本机待准备" }
        if controller.localStatus.contains("不可用") || controller.localStatus.contains("不支持") { return "本机不可用" }
        if controller.localStatus.contains("超时") { return "本机暂时超时" }
        return "本机快显"
    }
    private var gptSummary: String {
        if controller.mode == .mock { return "演示翻译" }
        if Keychain.load() == nil { return "GPT 未配置" }
        if controller.translationStatus.contains("翻译中") { return "GPT 正在完善" }
        if controller.translationStatus.contains("暂停") || controller.translationStatus.contains("取消") || controller.translationStatus.contains("不可用") { return "GPT 暂缓" }
        return "GPT 最终版"
    }
    private var recordingState: String {
        switch controller.session?.state {
        case .recording: return "录音中"
        case .paused: return "已暂停"
        case .interrupted: return "录音已中断"
        case .stopped, .recovered: return controller.elapsed > 0 ? "录音已保存" : "录音未开始"
        case nil: return "准备就绪"
        }
    }
    private var pauseButton: some View {
        Button { Task { await controller.pauseOrResume() } } label: {
            Label(controller.recording ? "暂停" : "继续", systemImage: controller.recording ? "pause.fill" : "play.fill")
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 48)
        }.buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(controller.busy).accessibilityIdentifier("pause-recording")
    }
    private var stopButton: some View {
        Button { confirmStop = true } label: { Label("停止", systemImage: "stop.fill").fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, minHeight: 48) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.primary).disabled(controller.busy)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .accessibilityIdentifier("stop-recording")
    }
    private var noteButton: some View {
        Button {
            Task {
                if let caption = controller.workspaceDraft ?? feed.rows.last.map({ WorkspaceCaption($0) }) { await controller.toggleMark(caption) }
                else if let session = controller.session { _ = await controller.writeNote(LectureNote(offset: controller.elapsed), session: session.id) }
            }
        } label: { Label("标记", systemImage: "bookmark").fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, minHeight: 48) }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(controller.noteBusy).accessibilityIdentifier("add-note")
            .contextMenu { Button("写笔记", systemImage: "square.and.pencil") { newNote() } }
    }
    private func newNote() {
            guard let session = controller.session else { return }
            let caption = controller.workspaceDraft ?? feed.rows.last.map { WorkspaceCaption($0) }
            let note = caption.flatMap { controller.note(for: $0.id) } ?? LectureNote(segmentID: caption?.id, offset: caption?.start ?? controller.elapsed, english: caption?.english ?? "")
            noteContext = NoteContext(sessionID: session.id, note: note)
    }
    private func captionRow(_ caption: WorkspaceCaption) -> some View {
        CaptionTextView(caption: caption, marked: controller.note(for: caption.id)?.marked == true)
            .id(caption.id)
            .onTapGesture(count: 2) { editNote(caption) }
            .onTapGesture { Task { await controller.toggleMark(caption) } }
            .contextMenu {
                Button("标记 / 取消标记", systemImage: "bookmark") { Task { await controller.toggleMark(caption) } }
                Button("写笔记", systemImage: "square.and.pencil") { editNote(caption) }
                Button("复制英文", systemImage: "doc.on.doc") { UIPasteboard.general.string = caption.english }
                if let chinese = caption.chinese { Button("复制中文", systemImage: "doc.on.doc") { UIPasteboard.general.string = chinese } }
            }
            .accessibilityAction(named: "标记此句") { Task { await controller.toggleMark(caption) } }
            .accessibilityAction(named: "写笔记") { editNote(caption) }
            .onAppear { controller.setRowVisible(caption.id, true) }
            .onDisappear { controller.setRowVisible(caption.id, false) }
            .onChange(of: caption) { _, _ in controller.captionDidRender(id: caption.id) }
    }
    private func editNote(_ caption: WorkspaceCaption) {
        guard let id = controller.session?.id else { return }
        noteContext = NoteContext(sessionID: id, note: controller.note(for: caption.id) ?? LectureNote(segmentID: caption.id, offset: caption.start, english: caption.english))
    }
    private func follow(_ proxy: ScrollViewProxy) {
        guard feed.following else { return }
        Task { @MainActor in await Task.yield(); guard feed.following else { return }; proxy.scrollTo("caption-bottom", anchor: .bottom) }
    }
    private func latest(_ proxy: ScrollViewProxy) async {
        let id = controller.session?.id
        let rows = await controller.latestWorkspaceRows()
        guard controller.session?.id == id else { return }
        feed.resume(latest: rows); hasEarlier = (rows.first?.start ?? 0) > 0.1; follow(proxy)
    }
    private func earlier() async {
        guard !loadingEarlier, let id = controller.session?.id, let first = feed.rows.first else { return }
        loadingEarlier = true; defer { loadingEarlier = false }
        do {
            let records = try await controller.store.segments(id)
            guard controller.session?.id == id else { return }
            let older = records.filter { $0.start < first.start }
            feed.prepend(Array(older.suffix(50))); hasEarlier = older.count > 50
        } catch { controller.warning = error.localizedDescription }
    }
}

struct NoteEditorView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dismiss) private var dismiss
    let context: NoteContext
    @State private var text: String
    @State private var marked: Bool
    @State private var discard = false
    @State private var error = ""
    init(context: NoteContext) { self.context = context; _text = State(initialValue: context.note.text); _marked = State(initialValue: context.note.marked) }
    private var changed: Bool { text != context.note.text || marked != context.note.marked }
    var body: some View {
        NavigationStack {
            Form {
                Section(SessionStore.timestamp(context.note.offset)) {
                    if !context.note.englishSnapshot.isEmpty { Text(context.note.englishSnapshot).font(.subheadline).foregroundStyle(.secondary).lineLimit(4) }
                    Toggle("标记这一刻", isOn: $marked)
                }
                Section("留给课后复习") { TextEditor(text: $text).frame(minHeight: 160).accessibilityIdentifier("note-text") }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.orange) } }
                Text("笔记独立保存，不会修改课堂原文。最多 6,000 字。").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("课堂笔记").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { if changed { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存笔记") { Task {
                        var note = context.note; note.text = text; note.marked = marked
                        if await controller.writeNote(note, session: context.sessionID) { dismiss() }
                        else { error = controller.warning.isEmpty ? "正在保存另一条笔记，请稍后再试。" : controller.warning }
                    } }.disabled(controller.noteBusy || text.count > 6000)
                }
            }
            .interactiveDismissDisabled(changed)
            .confirmationDialog("放弃未保存的笔记？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
            }
        }
    }
}
