import SwiftUI
import UIKit
import WLCore

struct WorkspaceCaption: Identifiable, Equatable {
    let id: UUID
    let start: Double
    let english: String
    let chinese: String?
    let phase: CaptionPhase
    let revision: Int
    var provisional = false
    init(_ segment: TranscriptSegment, chinese: String? = nil, english: String? = nil, phase: CaptionPhase? = nil) {
        id = segment.id; start = segment.start; self.english = english ?? segment.displayEnglish; self.chinese = chinese ?? segment.displayChinese
        self.phase = phase ?? segment.phase; revision = segment.sourceRevision
    }
    init(id: UUID, start: Double, english: String, chinese: String?, provisional: Bool) {
        self.id = id; self.start = start; self.english = english; self.chinese = chinese; self.provisional = provisional
        phase = chinese == nil ? .transcribing : .localDraft; revision = 0
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
            WorkspaceView().tabItem { Label("首页", systemImage: "house") }
            NavigationStack { LectureSettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(.williamAccent)
        .onChange(of: phase) { _, phase in
            controller.pictureInPicture.sceneChanged(phase)
            if phase != .inactive {
                controller.setForeground(phase == .active)
            }
        }
        .onChange(of: pipCaption, initial: true) { _, _ in controller.syncPictureInPicture() }
    }
    private var pipCaption: PiPCaptionState {
        PiPCaptionState(enabled: controller.pictureInPictureEnabled, session: controller.session?.id, active: controller.active,
            recording: controller.recording, course: controller.course, draft: controller.workspaceDraft,
            latest: controller.visible.last, elapsed: controller.elapsed)
    }
}
private struct PiPCaptionState: Equatable {
    var enabled: Bool
    var session: UUID?
    var active: Bool
    var recording: Bool
    var course: String
    var draft: WorkspaceCaption?
    var latest: TranscriptSegment?
    var elapsed: Double
}

struct CaptionTextView: View {
    let caption: WorkspaceCaption
    var marked = false
    @ObservedObject var lookup: WordLookupCoordinator
    let lookupOwner: UUID
    let lookupSession: UUID
    let lookupCourse: String
    var onLookupStart: () -> Void = {}
    var onSelect: () -> Void = {}
    var onMark: () -> Void = {}
    var onNote: () -> Void = {}
    var onPressing: () -> Void = {}
    var detail = false
    var onPlay: () -> Void = {}
    var playEnabled = false
    var beforePronunciation: (() -> Void)?
    @AppStorage("captionChineseSize") private var chineseSize = CaptionSize.standard
    @AppStorage("captionEnglishSize") private var englishSize = CaptionSize.standard
    @AppStorage("captionChineseTone") private var chineseTone = CaptionTone.dark
    @AppStorage("captionEnglishTone") private var englishTone = CaptionTone.standard
    @ScaledMetric(relativeTo: .body) private var typeScale = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                LookupEnglishText(lookup: lookup, owner: lookupOwner, session: lookupSession,
                    course: lookupCourse, caption: caption, fontSize: CGFloat(englishSize.englishPoints * typeScale), color: .primary.opacity(englishTone.opacity), onFocus: onLookupStart,
                    beforePronunciation: beforePronunciation)
                if marked { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.tint).accessibilityLabel("已标记").accessibilityIdentifier("caption-mark-\(caption.id.uuidString)") }
            }
            if lookup.owner == lookupOwner && lookup.focusedCaption == caption.id && !lookup.message.isEmpty {
                Text(lookup.message).font(.caption).foregroundStyle(Color.williamSecondary).accessibilityIdentifier("lookup-feedback")
            }
            if detail {
                sentence.contentShape(Rectangle()).contextMenu {
                    Button("从这里播放", systemImage: "play", action: onPlay).disabled(!playEnabled)
                    Button("笔记", systemImage: "square.and.pencil", action: onNote)
                    Button("标记 / 取消标记", systemImage: "bookmark", action: onMark)
                    Button("复制英文", systemImage: "doc.on.doc") { UIPasteboard.general.string = caption.english }
                    if let chinese = caption.chinese { Button("复制中文", systemImage: "doc.on.doc") { UIPasteboard.general.string = chinese } }
                }
            } else {
                sentence.contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5, perform: onNote, onPressingChanged: { if $0 { onPressing() } })
                .simultaneousGesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { tap in
                    onSelect(); if case .first = tap { onMark() }
                })
            }
        }
        .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("caption-\(caption.id.uuidString)")
    }
    private var sentence: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption.chinese ?? "…")
                .font(caption.chinese == nil ? .footnote : .system(size: chineseSize.chinesePoints * typeScale, weight: .regular)).lineSpacing(6)
                .foregroundStyle(caption.chinese == nil ? Color.williamSecondary : Color.primary.opacity(chineseTone.opacity))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("caption-chinese-\(caption.id.uuidString)")
            Text(SessionStore.readingTime(caption.start)).font(.caption2).monospacedDigit().foregroundStyle(Color.williamSecondary)
                .accessibilityIdentifier("caption-time-\(caption.id.uuidString)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var feed = CaptionFeed()
    @State private var lookupOwner = UUID()
    #if DEBUG
    @State private var fixtureLookupScheduled = false
    #endif
    @State private var nearBottom = true
    @State private var readerDragged = false
    @State private var scrollIsIdle = true
    @State private var viewportSize = CGSize.zero
    @State private var settings = false
    @State private var status = false
    @State private var courses = false
    @State private var confirmStop = false
    @State private var noteContext: NoteContext?
    @State private var savedDetail = false
    @State private var liveSummary = false
    @State private var loadingEarlier = false
    @State private var hasEarlier = false
    @State private var paneSessionID: UUID?
    @State private var selectedCaption: WorkspaceCaption?
    @State private var savedSession: LectureSession?
    private var live: WorkspaceCaption? {
        controller.workspaceDraft
    }
    private var markTarget: WorkspaceCaption? {
        if let chosen = selectedCaption {
            return feed.rows.first(where: { $0.id == chosen.id }).map { WorkspaceCaption($0, chinese: controller.captionChinese($0)) } ?? chosen
        }
        return controller.workspaceDraft ?? feed.rows.last.map { WorkspaceCaption($0) }
    }
    private var bottomID: UUID? { live?.id ?? feed.rows.last?.id }

    var body: some View {
        NavigationStack {
            Group {
                if controller.active || controller.starting || controller.stopping {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 24) {
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
                            .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? .infinity : 720, alignment: .leading)
                            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
                            .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("caption-scroll")
                        .defaultScrollAnchor(.bottom, for: .initialOffset)
                        .defaultScrollAnchor(feed.following ? .bottom : .top, for: .sizeChanges)
                        .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in viewportSize = size }
                        .task(id: viewportSize) {
                            let sessionID = controller.session?.id
                            guard !controller.lookup.isInteracting, feed.following, viewportSize != .zero else { return }
                            // Rotation changes the lazy stack's measured heights across several layouts.
                            // Re-anchor after it settles; cancellation prevents a prior resize or reader
                            // gesture from dragging the viewport back to the end.
                            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                            guard !Task.isCancelled, !controller.lookup.isInteracting, feed.following, controller.session?.id == sessionID else { return }
                            proxy.scrollTo("caption-bottom", anchor: .bottom)
                        }
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                        } action: { _, value in nearBottom = value; resumeIfAtBottom(proxy) }
                        .onScrollPhaseChange { _, phase in
                            scrollIsIdle = phase == .idle
                            if phase == .interacting { controller.lookup.readerScrolled(owner: lookupOwner); readerDragged = true; feed.suspend() }
                            // Layout/geometry may arrive after the idle event. Keep the
                            // drag intent until either callback observes the visible end.
                            resumeIfAtBottom(proxy)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !feed.following {
                                Button { Task { await latest(proxy) } } label: {
                                    Image(systemName: "arrow.down").font(.subheadline).frame(width: 44, height: 44)
                                }
                                .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("回到最新")
                                .padding(.trailing, 22).padding(.bottom, 12).accessibilityIdentifier("follow-latest")
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            #if DEBUG
                            if controller.isUIFixture && ProcessInfo.processInfo.arguments.contains("--wl-live-arrival") {
                                Button("模拟新增字幕") { Task { await controller.appendUIFixtureCaption() } }
                                    .accessibilityIdentifier("fixture-append-caption")
                            }
                            #endif
                        }
                        .onChange(of: controller.latestCaptionUpdate) { _, segment in
                            if let segment {
                                if selectedCaption?.id == segment.id { selectedCaption = WorkspaceCaption(segment, chinese: controller.captionChinese(segment)) }
                                feed.merge([segment]); follow(proxy)
                            }
                        }
                        .onChange(of: controller.visible) { _, segments in feed.merge(segments); follow(proxy) }
                        .onChange(of: controller.foregroundRefresh) { _, refresh in
                            let classroom = controller.session?.id, retained = Set(feed.rows.map(\.id))
                            Task {
                                let rows = await controller.workspaceRows(retaining: retained)
                                guard controller.session?.id == classroom, controller.foregroundRefresh == refresh else { return }
                                feed.merge(rows); follow(proxy)
                            }
                        }
                        .onChange(of: controller.workspaceDraft) { _, _ in follow(proxy) }
                        .task(id: controller.session?.id) {
                            let id = controller.session?.id
                            let rows = await controller.latestWorkspaceRows()
                            guard controller.session?.id == id else { return }
                            if paneSessionID != id { controller.lookup.close(owner: lookupOwner); paneSessionID = id; feed = CaptionFeed(); selectedCaption = nil }
                            selectedCaption = nil; feed.resume(latest: rows); hasEarlier = (rows.first?.start ?? 0) > 0.1; follow(proxy)
                        }
                        .transaction { $0.animation = nil }
                        .safeAreaInset(edge: .top, spacing: 0) { compactStatus }
                        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
                    }
                } else {
                    HistoryList()
                        .safeAreaInset(edge: .top, spacing: 0) { compactStatus }
                        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(controller.active ? controller.course : "William Lecture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if controller.active {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { controller.generateLiveSummary(); liveSummary = true } label: { Image(systemName: "text.badge.checkmark") }
                            .frame(minWidth: 44, minHeight: 44).accessibilityLabel("总结当前内容").accessibilityIdentifier("summarize-current")
                            .disabled(controller.visible.isEmpty && controller.workspaceDraft == nil)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Button { courses = true } label: {
                        VStack(spacing: 3) {
                            HStack(spacing: 4) {
                                Text(controller.course).font(.headline).lineLimit(1)
                                if !controller.active { Image(systemName: "chevron.down").font(.caption2) }
                            }
                            if controller.active || controller.busy {
                                HStack(spacing: 5) {
                                    Circle().fill(controller.recording ? Color.williamAccent : Color.williamSecondary).frame(width: 5, height: 5)
                                    Text(recordingState).font(.caption).foregroundStyle(Color.williamSecondary)
                                }
                            }
                        }.foregroundStyle(Color(uiColor: .label)).frame(minHeight: 44)
                    }.disabled(controller.active || controller.busy).accessibilityLabel("选择课程，\(controller.course)").accessibilityIdentifier("course-picker")
                }
                if controller.pictureInPictureEnabled && controller.active && controller.pictureInPicture.supported {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { controller.pictureInPicture.start() } label: {
                            CaptionPictureInPicturePreview(coordinator: controller.pictureInPicture)
                                .frame(width: 56, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay { Image(systemName: "pip.enter").font(.system(size: 17)).foregroundStyle(.white).shadow(radius: 2) }
                                .frame(minWidth: 56, minHeight: 44)
                        }.buttonStyle(.plain).accessibilityLabel("打开字幕小窗").accessibilityIdentifier("open-caption-pip")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("录课设置").frame(minWidth: 44, minHeight: 44)
                }
            }
            .toolbar(controller.active ? .hidden : .visible, for: .tabBar)
            .sheet(isPresented: $settings) { NavigationStack { LectureSettingsView(inSheet: true) } }
            .sheet(isPresented: $liveSummary, onDismiss: { controller.liveSummary.cancel() }) {
                LiveSummaryView(summary: controller.liveSummary, regenerate: { controller.generateLiveSummary() })
            }
            .onChange(of: controller.session?.id) { _, _ in liveSummary = false; controller.liveSummary.cancel(clear: true) }
            .sheet(isPresented: $status) { NavigationStack { DiagnosticsView() } }
            .sheet(isPresented: $courses) { CoursePickerView() }
            .sheet(item: $noteContext) { NoteEditorView(context: $0).id($0.id) }
            .navigationDestination(isPresented: $savedDetail) {
                if let session = savedSession { LessonDetailView(session: session) }
            }
            .onDisappear { controller.lookup.close(owner: lookupOwner) }
            .alert("结束这节课？", isPresented: $confirmStop) {
                Button("继续录课", role: .cancel) {}
                Button("结束并保存") { Task {
                    await controller.stop()
                    if let session = controller.session, session.state == .stopped { selectedCaption = nil; savedSession = session; savedDetail = true; UINotificationFeedbackGenerator().notificationOccurred(.success) }
                } }
            } message: { Text("音频和文字将保存在课堂记录中。") }
        }
    }
    private var emptyState: some View {
        Group {
            if controller.active { Text("暂无字幕").font(.subheadline).foregroundStyle(Color.williamSecondary) }
            else { Color.clear.frame(height: 80) }
        }.padding(.top, 48).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var compactStatus: some View {
        if !controller.warning.isEmpty {
            Button("录音或保存异常") { status = true }
                .font(.footnote).foregroundStyle(Color.williamWarning).frame(minHeight: 44).accessibilityIdentifier("system-warning")
                .accessibilityValue(controller.warning)
        } else if controller.active && !controller.speechError.isEmpty {
            Button("转写暂不可用 · 重试") { Task { await controller.retrySpeech() } }
                .font(.footnote).foregroundStyle(Color.williamWarning).frame(minHeight: 44)
        } else if controller.active && controller.translationBlocked {
            Button("翻译暂不可用") { status = true }
                .font(.footnote).foregroundStyle(Color.williamWarning).frame(minHeight: 44)
        } else if controller.mode == .mock {
            Text("演示模式").font(.caption).foregroundStyle(Color.williamSecondary)
        }
    }
    private var controls: some View {
        VStack(spacing: 16) {
            if controller.active || controller.starting || controller.stopping {
            HStack(spacing: 18) {
                Rectangle().fill(Color.williamSecondary.opacity(0.15)).frame(height: 0.5)
                Text(SessionStore.readingTime(controller.elapsed)).font(.system(.callout, design: .monospaced))
                    .monospacedDigit().foregroundStyle(Color.williamSecondary).fixedSize()
                    .accessibilityIdentifier("recording-time")
                Rectangle().fill(Color.williamSecondary.opacity(0.15)).frame(height: 0.5)
            }
            }
            if controller.active {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 28) { pauseButton; stopButton; noteButton }
                    HStack(spacing: 12) { pauseButton; stopButton; noteButton }
                }
            } else {
                Button { Task { await controller.start(); UIImpactFeedbackGenerator(style: .light).impactOccurred() } } label: {
                    Group {
                        if controller.busy { ProgressView().tint(Color(uiColor: .systemBackground)) }
                        else { Image(systemName: "mic.fill").font(.system(size: 25)) }
                    }.frame(width: 58, height: 58).foregroundStyle(Color(uiColor: .systemBackground))
                        .background(Color.williamAccent, in: Circle())
                }.buttonStyle(.plain).disabled(controller.busy).accessibilityLabel("开始录音").accessibilityIdentifier("start-recording")
            }
        }.frame(maxWidth: 720).padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 14)
            .frame(maxWidth: .infinity).background(.bar)
    }
    private var recordingState: String {
        if controller.starting { return "正在准备" }
        if controller.stopping { return "正在保存" }
        switch controller.session?.state {
        case .recording: return "录音中"
        case .paused: return "已暂停"
        case .interrupted: return "录音已中断"
        case .stopped, .recovered: return "已保存"
        case nil: return ""
        }
    }
    private var pauseButton: some View {
        Button { Task { await controller.pauseOrResume(); UIImpactFeedbackGenerator(style: .light).impactOccurred() } } label: {
            Image(systemName: controller.recording ? "pause.fill" : "play.fill").font(.system(size: 21))
                .frame(width: 68, height: 48).background(Color.williamAccent.opacity(0.07), in: Capsule())
        }.buttonStyle(.plain).disabled(controller.busy).accessibilityLabel(controller.recording ? "暂停" : "继续").accessibilityIdentifier("pause-recording")
    }
    private var stopButton: some View {
        Button { confirmStop = true } label: {
            Image(systemName: "stop.fill").font(.system(size: 23)).frame(width: 86, height: 52)
                .foregroundStyle(Color(uiColor: .systemBackground)).background(Color.williamAccent, in: Capsule())
        }.buttonStyle(.plain).disabled(controller.busy).accessibilityLabel("停止").accessibilityIdentifier("stop-recording")
    }
    private var noteButton: some View {
        Button {
            Task {
                if let caption = markTarget { await controller.toggleMark(caption) }
                else if let session = controller.session { _ = await controller.writeNote(LectureNote(offset: controller.elapsed), session: session.id) }
            }
        } label: {
            Image(systemName: markTarget.flatMap { controller.note(for: $0.id) }?.marked == true ? "bookmark.fill" : "bookmark")
                .font(.system(size: 21)).frame(width: 68, height: 48).background(Color.williamAccent.opacity(0.07), in: Capsule())
        }.buttonStyle(.plain).disabled(controller.noteBusy).accessibilityLabel("标记选中句，未选中时标记最新句").accessibilityIdentifier("add-note")
            .contextMenu { Button("笔记", systemImage: "square.and.pencil") { newNote() } }
    }
    private func newNote() {
            guard let session = controller.session else { return }
            let caption = markTarget
            let note = caption.flatMap { controller.note(for: $0.id) } ?? LectureNote(segmentID: caption?.id, offset: caption?.start ?? controller.elapsed, english: caption?.english ?? "")
            noteContext = NoteContext(sessionID: session.id, note: note)
    }
    private func captionRow(_ caption: WorkspaceCaption) -> some View {
        CaptionTextView(caption: caption, marked: controller.note(for: caption.id)?.marked == true,
            lookup: controller.lookup, lookupOwner: lookupOwner, lookupSession: controller.session?.id ?? lookupOwner, lookupCourse: controller.course,
            onLookupStart: {
                readerDragged = false; selectedCaption = caption; feed.suspend()
                #if DEBUG
                if controller.isUIFixture && ProcessInfo.processInfo.arguments.contains("--wl-lookup-arrival") && !fixtureLookupScheduled {
                    fixtureLookupScheduled = true
                    Task { try? await Task.sleep(for: .seconds(2)); await controller.appendUIFixtureCaption() }
                }
                #endif
            },
            onSelect: { controller.lookup.close(owner: lookupOwner); readerDragged = false; selectedCaption = caption; feed.suspend() },
            onMark: { Task { await controller.toggleMark(caption) } },
            onNote: { controller.lookup.close(owner: lookupOwner); readerDragged = false; selectedCaption = caption; feed.suspend(); editNote(caption) },
            onPressing: { readerDragged = false; feed.suspend() })
            .id(caption.id)
            .background(selectedCaption?.id == caption.id ? Color.williamAccent.opacity(0.04) : Color.clear)
            .accessibilityAction(named: "标记此句") { Task { await controller.toggleMark(caption) } }
            .accessibilityAction(named: "写笔记") { editNote(caption) }
            .accessibilityAction(named: "复制英文") { UIPasteboard.general.string = caption.english }
            .onAppear { controller.setRowVisible(caption.id, true); controller.captionDidRender(id: caption.id, english: caption.english) }
            .onDisappear { controller.setRowVisible(caption.id, false) }
            .onChange(of: caption) { _, _ in controller.captionDidRender(id: caption.id, english: caption.english) }
    }
    private func editNote(_ caption: WorkspaceCaption) {
        guard let id = controller.session?.id else { return }
        noteContext = NoteContext(sessionID: id, note: controller.note(for: caption.id) ?? LectureNote(segmentID: caption.id, offset: caption.start, english: caption.english))
    }
    private func follow(_ proxy: ScrollViewProxy) {
        guard !controller.lookup.isInteracting, feed.following else { return }
        Task { @MainActor in await Task.yield(); guard !controller.lookup.isInteracting, feed.following else { return }; proxy.scrollTo("caption-bottom", anchor: .bottom) }
    }
    private func resumeIfAtBottom(_ proxy: ScrollViewProxy) {
        guard !controller.lookup.isInteracting, readerDragged, scrollIsIdle, nearBottom, !feed.following else { return }
        readerDragged = false
        Task { await latest(proxy, automatic: true) }
    }
    private func latest(_ proxy: ScrollViewProxy, automatic: Bool = false) async {
        if !automatic { controller.lookup.close(owner: lookupOwner) }
        let id = controller.session?.id
        let rows = await controller.latestWorkspaceRows()
        guard controller.session?.id == id, !automatic || (!controller.lookup.isInteracting && scrollIsIdle && nearBottom && !readerDragged) else { return }
        selectedCaption = nil; readerDragged = false; feed.resume(latest: rows); hasEarlier = (rows.first?.start ?? 0) > 0.1; follow(proxy)
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
                    if !context.note.englishSnapshot.isEmpty { Text(context.note.englishSnapshot).font(.subheadline).foregroundStyle(Color.williamSecondary).lineLimit(4).accessibilityIdentifier("note-source") }
                    Toggle("标记这一刻", isOn: $marked)
                }
                Section("笔记") { TextEditor(text: $text).frame(minHeight: 160).accessibilityIdentifier("note-text") }
                if !error.isEmpty { Section { Text(error).foregroundStyle(Color.williamWarning) } }
                Text("笔记独立保存，不会修改课堂原文。最多 6,000 字。").font(.caption).foregroundStyle(Color.williamSecondary)
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
