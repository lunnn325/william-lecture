import SwiftUI
import UIKit
import WLCore

struct HistoryView: View {
    @EnvironmentObject private var controller: LectureController
    @State private var search = ""
    private var filtered: [LectureSession] {
        controller.history.filter { search.isEmpty || $0.course.localizedCaseInsensitiveContains(search) || $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.startedAt.formatted().contains(search) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if controller.history.isEmpty { ContentUnavailableView("暂无记录", systemImage: "text.book.closed") }
                    else if filtered.isEmpty { ContentUnavailableView.search(text: search) }
                    ForEach(filtered) { session in
                        NavigationLink { LessonDetailView(session: session) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(session.displayTitle).font(.headline).foregroundStyle(.primary)
                                if let preview = session.preview, !preview.isEmpty {
                                    Text(preview).font(.subheadline).foregroundStyle(Color.williamSecondary).lineLimit(2).lineSpacing(3)
                                }
                                HStack(spacing: 6) {
                                    Text(session.startedAt.formatted(.dateTime.month().day().hour().minute()))
                                    Text("·"); Text(SessionStore.readingTime(session.duration)).monospacedDigit()
                                    if let count = session.markCount, count > 0 { Text("·"); Image(systemName: "bookmark"); Text("\(count)") }
                                    if ![.stopped, .recovered].contains(session.state) { Text("· 录音中") }
                                    if session.state == .recovered { Text("· 已恢复") }
                                }.font(.caption).foregroundStyle(Color.williamSecondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.williamSecondary.opacity(0.08), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: 720).padding(20).frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("课堂记录")
                .searchable(text: $search, prompt: "课程或日期")
                .task { await controller.refreshHistory() }
                .refreshable { await controller.refreshHistory() }
                .onReceive(controller.processing.$change) { _ in Task { await controller.refreshHistory() } }
        }
    }
}

struct LessonDetailView: View {
    @EnvironmentObject private var controller: LectureController
    @State private var session: LectureSession
    @State private var segments: [TranscriptSegment] = []
    @State private var notes: [LectureNote] = []
    @State private var document: LessonContent?
    @State private var totals = UsageTotals([])
    @State private var page = 0
    @State private var markedOnly = false
    @State private var original = false
    @State private var tab = 0
    @State private var export = false
    @State private var error = ""
    @State private var noteContext: NoteContext?
    @State private var renaming = false
    @State private var name = ""
    @State private var shareFiles: [URL] = []
    @State private var sharing = false
    @State private var showUsage = false
    @State private var mapScale = 1.0
    @State private var mapBaseScale = 1.0
    @State private var mapSize = CGSize(width: 950, height: 520)
    @State private var viewportHeight: CGFloat = 800
    @State private var jumpID: UUID?
    @State private var jumpRequest = 0
    @StateObject private var playback = LecturePlayback()
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var resumeAfterScrub = false
    var inSheet = false
    init(session: LectureSession, inSheet: Bool = false) { _session = State(initialValue: session); self.inSheet = inSheet }
    private var filtered: [TranscriptSegment] {
        markedOnly ? segments.filter { s in notes.contains { $0.segmentID == s.id && ($0.marked || !$0.text.isEmpty) } } : segments
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    metadata
                    player
                    Picker("内容", selection: $tab) { Text("全文").tag(0); Text("摘要").tag(1); Text("思维导图").tag(2) }.pickerStyle(.segmented)
                    if let d = document, d.state != .completed {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.state.label).font(.caption).foregroundStyle(Color.williamSecondary)
                            if let message = d.error { Text(message).font(.footnote).foregroundStyle(Color.williamWarning) }
                            if !d.state.automatic || d.state == .waitingForNetwork {
                                Button("重试") { Task { await controller.processing.enqueue(session, retry: true); await load() } }.disabled(controller.active)
                            }
                        }
                    }
                    if tab == 0 { transcript }
                    else if tab == 1 { summary }
                    else { mindMap }
                    if document == nil {
                        Button("整理记录") { Task { await controller.processing.enqueue(session); await load() } }.disabled(controller.active)
                    }
                    if let failure = controller.processing.enqueueFailures[session.id] {
                        Text("整理记录未保存：\(failure)").font(.footnote).foregroundStyle(Color.williamWarning)
                    }
                    if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(Color.williamWarning) }
                }.frame(maxWidth: 720).padding(24).frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemBackground))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, height in viewportHeight = height }
                .onChange(of: jumpRequest) { _, _ in
                    guard let id = jumpID else { return }
                    Task { try? await Task.sleep(for: .milliseconds(100)); proxy.scrollTo(id, anchor: .top); jumpID = nil }
                }
        }
        .navigationTitle(session.displayTitle).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { export = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("导出课堂") }
            ToolbarItem(placement: .topBarTrailing) { Button { name = session.displayTitle; renaming = true } label: { Image(systemName: "ellipsis") }.accessibilityLabel("修改名称") }
        }
        .alert("课堂名称", isPresented: $renaming) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") { Task { do { try await controller.store.rename(session.id, title: name); await load(); await controller.refreshHistory() } catch { self.error = error.localizedDescription } } }
        }
        .sheet(isPresented: $export) { ExportView(session: session) }
        .sheet(isPresented: $sharing) { ActivityShareView(files: shareFiles) }
        .sheet(item: $noteContext, onDismiss: { Task { await load() } }) { NoteEditorView(context: $0) }
        .task {
            playback.recordingActive = { controller.active }
            await load()
            do { let offsets = try await controller.store.audioOffsets(session.id); await playback.prepare(session: session, folder: controller.store.folder(session.id), offsets: offsets) }
            catch { self.error = error.localizedDescription }
        }
        .onReceive(controller.processing.$change) { _ in Task { await load() } }
        .onDisappear { playback.stop() }
        .onChange(of: controller.active) { _, active in if active { playback.stop() } }
    }
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(session.startedAt.formatted(.dateTime.month().day().hour().minute()))
                Text("·"); Text(SessionStore.readingTime(session.duration)).monospacedDigit()
                if !notes.isEmpty { Text("· \(notes.filter(\.marked).count) 个标记") }
            }.font(.caption).foregroundStyle(Color.williamSecondary)
            if session.state == .recovered { Text("已恢复，末尾录音需核对").font(.footnote).foregroundStyle(Color.williamWarning) }
            if totals.total > 0 || totals.unknown > 0 {
                Button { showUsage.toggle() } label: {
                    Text(totals.total == 0 ? "用量未返回" : "\(totals.total.formatted()) tokens\(totals.unknown > 0 ? " · 部分用量未返回" : "")").font(.caption).foregroundStyle(Color.williamSecondary)
                }.buttonStyle(.plain)
                if showUsage {
                    if totals.total > 0 { Text("已返回统计：输入 \(totals.input) · 输出 \(totals.output)\n实时 \(totals.live) · 课后 \(totals.postLesson)").font(.caption).foregroundStyle(Color.williamSecondary) }
                    if totals.unknown > 0 { Text("\(totals.unknown) 次请求的用量未返回").font(.caption).foregroundStyle(Color.williamSecondary) }
                }
            }
        }
    }
    @ViewBuilder private var player: some View {
        if playback.loading { ProgressView("正在读取录音") }
        else if !session.audioFiles.isEmpty {
            VStack(spacing: 8) {
                Slider(value: Binding(get: { scrubbing ? scrubValue : playback.position }, set: { scrubValue = $0 }), in: 0...max(1, playback.duration)) { editing in
                    if editing { scrubbing = true; scrubValue = playback.position; resumeAfterScrub = playback.playing; playback.pause() }
                    else { playback.seek(to: scrubValue, resume: resumeAfterScrub); scrubbing = false }
                }.disabled(!playback.ready || controller.active).accessibilityLabel("播放位置")
                HStack {
                    Text(SessionStore.readingTime(scrubbing ? scrubValue : playback.position)); Spacer(); Text(SessionStore.readingTime(playback.duration))
                }.font(.caption).monospacedDigit().foregroundStyle(Color.williamSecondary)
                HStack(spacing: 32) {
                    Button { playback.seek(to: playback.position - 15, resume: playback.playing) } label: { Image(systemName: "gobackward.15").frame(width: 44, height: 44) }.accessibilityLabel("后退十五秒")
                    Button { playback.toggle() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("播放或暂停").accessibilityIdentifier("play-lecture")
                    Button { playback.seek(to: playback.position + 15, resume: playback.playing) } label: { Image(systemName: "goforward.15").frame(width: 44, height: 44) }.accessibilityLabel("前进十五秒")
                }.buttonStyle(.plain).disabled(!playback.ready || controller.active)
            }
        }
        if !playback.error.isEmpty { Text(playback.error).font(.footnote).foregroundStyle(Color.williamWarning) }
    }
    @ViewBuilder private var transcript: some View {
        HStack {
            Picker("筛选", selection: $markedOnly) { Text("全部").tag(false); Text("标记").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 180)
            Spacer()
            if document?.corrected.isEmpty == false { Button(original ? "修订" : "原始") { original.toggle() }.font(.caption) }
        }.onChange(of: markedOnly) { _, _ in if jumpID == nil { page = 0 } }
        if filtered.isEmpty { Text(markedOnly ? "暂无标记" : "暂无文字稿").foregroundStyle(Color.williamSecondary) }
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(Array(filtered.dropFirst(page * 50).prefix(50))) { segment in
                detailCaption(segment).id(segment.id)
            }
        }
        if filtered.count > 50 {
            HStack {
                Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(page == 0)
                Spacer(); Text("\(page + 1) / \((filtered.count + 49) / 50)").font(.caption)
                Spacer(); Button { page += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled((page + 1) * 50 >= filtered.count)
            }
        }
    }
    @ViewBuilder private var summary: some View {
        if let d = document, !d.outline.isEmpty {
            if let overview = d.overview { Text(overview).font(.body).lineSpacing(6) }
            ForEach(d.outline) { node in StudySummaryNode(node: node, depth: 0, times: Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.start) }), jump: jump) }
            Button { Task { await shareStudy() } } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("分享摘要")
        } else { Text("暂无摘要").font(.subheadline).foregroundStyle(Color.williamSecondary) }
    }
    @ViewBuilder private var mindMap: some View {
        if let d = document, !d.outline.isEmpty {
            HStack {
                Button { mapScale = max(0.6, mapScale - 0.2) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("缩小")
                Button { mapScale = min(2.0, mapScale + 0.2) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("放大")
                Spacer()
                Button { Task { await shareMap() } } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("分享思维导图")
            }
            ScrollView([.horizontal, .vertical]) {
                LessonMindMap(title: d.title ?? session.course, nodes: d.outline, jump: jump)
                    .frame(width: 950)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { _, size in mapSize = size }
                    .scaleEffect(mapScale, anchor: .topLeading)
                    .frame(width: mapSize.width * mapScale, height: mapSize.height * mapScale, alignment: .topLeading)
                    .padding(16)
                    .simultaneousGesture(MagnifyGesture().onChanged { value in mapScale = min(2, max(0.6, mapBaseScale * value.magnification)) }.onEnded { _ in mapBaseScale = mapScale })
            }.frame(height: min(560, max(240, viewportHeight * 0.58)))
        } else { Text("暂无思维导图").font(.subheadline).foregroundStyle(Color.williamSecondary) }
    }
    private func detailCaption(_ segment: TranscriptSegment) -> some View {
        let correction = original ? nil : document?.correction(for: segment)
        let marked = notes.first { $0.segmentID == segment.id }?.marked == true
        let chinese = correction?.chinese ?? segment.exportChinese
        let terminal = document.map { !$0.state.automatic } ?? true
        return VStack(alignment: .leading, spacing: 8) {
            CaptionTextView(caption: WorkspaceCaption(segment, chinese: chinese, english: correction?.english,
                phase: chinese == nil && terminal ? .failed : nil), marked: marked)
            if let note = notes.first(where: { $0.segmentID == segment.id }), !note.text.isEmpty {
                Text(note.text).font(.footnote).foregroundStyle(Color.williamSecondary)
            }
        }.contextMenu {
            Button("从这里播放", systemImage: "play") { playback.seek(to: segment.start, resume: true) }.disabled(controller.active || !playback.ready)
            Button("笔记", systemImage: "square.and.pencil") { edit(segment) }
            Button("标记 / 取消标记", systemImage: "bookmark") { Task {
                var note = notes.first { $0.segmentID == segment.id } ?? LectureNote(segmentID: segment.id, offset: segment.start, english: segment.english, marked: false)
                note.marked.toggle(); _ = await controller.writeNote(note, session: session.id); await load()
            } }
            Button("复制英文", systemImage: "doc.on.doc") { UIPasteboard.general.string = correction?.english ?? segment.english }
            if let chinese { Button("复制中文", systemImage: "doc.on.doc") { UIPasteboard.general.string = chinese } }
        }
    }
    private func jump(_ ids: [UUID]) {
        guard let id = ids.first, let index = segments.firstIndex(where: { $0.id == id }) else { return }
        markedOnly = false; page = index / 50; tab = 0
        jumpID = id; jumpRequest += 1
        if playback.ready && !controller.active { playback.seek(to: segments[index].start, resume: false) }
    }
    private func edit(_ segment: TranscriptSegment) {
        noteContext = NoteContext(sessionID: session.id, note: notes.first { $0.segmentID == segment.id } ?? LectureNote(segmentID: segment.id, offset: segment.start, english: segment.english))
    }
    private func load() async {
        do {
            if let saved = try await controller.store.sessions().first(where: { $0.id == session.id }) { session = saved }
            segments = try await controller.store.segments(session.id); notes = try await controller.store.notes(session.id)
            document = try await controller.store.content(session.id); totals = try await controller.store.usageTotals(session.id)
            page = min(page, max(0, (filtered.count - 1) / 50)); error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func shareStudy() async {
        do { shareFiles = [try await controller.store.exportStudy(session.id)]; sharing = true }
        catch { self.error = error.localizedDescription }
    }
    private func shareMap() async {
        guard let d = document else { return }
        let renderer = ImageRenderer(content: LessonMindMap(title: d.title ?? session.course, nodes: d.outline, jump: { _ in })
            .frame(width: 1000).padding(30).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 1.5
        guard let data = renderer.uiImage?.pngData() else { error = "图片未生成"; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WL-map-\(UUID()).png")
        do { try data.write(to: url, options: .atomic); shareFiles = [url, try await controller.store.exportStudy(session.id)]; sharing = true }
        catch { self.error = error.localizedDescription }
    }
}

struct StudySummaryNode: View {
    let node: StudyNode
    let depth: Int
    let times: [UUID: Double]
    let jump: ([UUID]) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { jump(node.segmentIDs) } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(node.title).font(depth == 0 ? .headline : .subheadline.weight(.medium)).foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    if let first = node.segmentIDs.first, let offset = times[first] { Text(SessionStore.readingTime(offset)).font(.caption).foregroundStyle(Color.williamSecondary) }
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("summary-source-\(node.id)")
            if !node.body.isEmpty { Text(node.body).font(.body).lineSpacing(6) }
            ForEach(node.children) { child in StudySummaryNode(node: child, depth: depth + 1, times: times, jump: jump).padding(.leading, 12) }
        }.padding(.vertical, 6)
    }
}
struct LessonMindMap: View {
    let title: String
    let nodes: [StudyNode]
    let jump: ([UUID]) -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Text(title).font(.headline).frame(width: 160)
            Rectangle().fill(Color.williamAccent.opacity(0.25)).frame(width: 1)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(nodes) { node in MindMapBranch(node: node, jump: jump) }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
struct MindMapBranch: View {
    let node: StudyNode
    let jump: ([UUID]) -> Void
    var body: some View {
        HStack(spacing: 16) {
            Button { jump(node.segmentIDs) } label: { Text(node.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).frame(width: 180, alignment: .leading).frame(minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("map-source-\(node.id)")
            if !node.children.isEmpty {
                Rectangle().fill(Color.williamAccent.opacity(0.2)).frame(width: 1)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(node.children) { child in
                        VStack(alignment: .leading, spacing: 6) {
                            Button { jump(child.segmentIDs) } label: { Text(child.title).font(.subheadline).foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                            ForEach(child.children) { leaf in Button { jump(leaf.segmentIDs) } label: { Text(leaf.title).font(.caption).foregroundStyle(Color.williamSecondary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain) }
                        }.frame(width: 280, alignment: .leading)
                    }
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct ExportView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dismiss) private var dismiss
    let session: LectureSession
    @State private var language = ExportLanguage.bilingual
    @State private var markdown = false
    @State private var original = false
    @State private var audio = false
    @State private var notes = true
    @State private var diagnostics = false
    @State private var working = false
    @State private var task: Task<Void, Never>?
    @State private var files: [URL] = []
    @State private var sharing = false
    @State private var error = ""
    private var exportChoice: String { "\(language.rawValue)|\(markdown)|\(original)|\(audio)|\(notes)|\(diagnostics)" }
    var body: some View {
        NavigationStack {
            Form {
                Section("文字稿") {
                    Picker("语言", selection: $language) { Text("双语").tag(ExportLanguage.bilingual); Text("英文").tag(ExportLanguage.english); Text("中文").tag(ExportLanguage.chinese) }.accessibilityIdentifier("export-language")
                    Picker("文件格式", selection: $markdown) { Text("TXT").tag(false); Text("Markdown").tag(true) }.pickerStyle(.segmented)
                    Toggle("原始转写", isOn: $original)
                    Text("默认导出修订全文；处理未完成和缺失内容会标明。").font(.footnote).foregroundStyle(Color.williamSecondary)
                }.disabled(working)
                Section("同时带走") {
                    Toggle("标记与笔记", isOn: $notes)
                    Toggle("整节录音 · M4A", isOn: $audio).disabled(session.audioFiles.isEmpty)
                    Toggle("诊断文件", isOn: $diagnostics)
                    Text("笔记独立成文件；诊断用于检查延迟或故障。所有文件均为生成时的快照。").font(.footnote).foregroundStyle(Color.williamSecondary)
                }.disabled(working)
                Section {
                    Button(working ? "正在准备文件…" : "生成导出文件") { generate() }.disabled(working || controller.active || controller.busy)
                    if working { ProgressView("音频较长时需要一些时间…"); Button("取消导出") { task?.cancel() } }
                    if !files.isEmpty {
                        Button { sharing = true } label: { Label("分享 / 保存到文件", systemImage: "square.and.arrow.up") }.disabled(working)
                        Text("已准备 \(files.count) 个文件").font(.caption).foregroundStyle(Color.williamSecondary)
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(Color.williamWarning).font(.footnote) }
                    if controller.active { Text("请先结束录课，等待保存完成后再导出。").font(.footnote).foregroundStyle(Color.williamSecondary) }
                }
            }
                .navigationTitle("导出课堂").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { task?.cancel(); dismiss() } } }
                .sheet(isPresented: $sharing) { ActivityShareView(files: files) }
                .onChange(of: exportChoice) { _, _ in files = []; error = "" }
                .onDisappear { task?.cancel() }
        }
    }
    private func generate() {
        guard !working else { return }; working = true; files = []; error = ""
        let selectedLanguage = language, selectedMarkdown = markdown, selectedOriginal = original, includeAudio = audio, includeNotes = notes, includeDiagnostics = diagnostics
        task = Task {
            defer { working = false }
            do {
                let (text, diagnostic) = try await controller.exportText(session, language: selectedLanguage, markdown: selectedMarkdown, original: selectedOriginal)
                var result = [text]; try Task.checkCancellation()
                if includeNotes { result.append(try await controller.store.exportNotes(session.id, markdown: selectedMarkdown)) }
                if includeDiagnostics { result.append(diagnostic) }
                if includeAudio { result.append(try await controller.exportAudio(session)) }
                try Task.checkCancellation(); files = result
            } catch is CancellationError { self.error = "导出已取消，原始记录保留。" }
            catch { self.error = error.localizedDescription }
        }
    }
}
struct ActivityShareView: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: files, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
