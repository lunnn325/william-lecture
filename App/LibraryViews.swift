import SwiftUI
import WLCore

struct HistoryView: View {
    @EnvironmentObject private var controller: LectureController
    @State private var search = ""
    private var filtered: [LectureSession] {
        controller.history.filter { search.isEmpty || $0.course.localizedCaseInsensitiveContains(search) || $0.startedAt.formatted().contains(search) }
    }
    var body: some View {
        NavigationStack {
            List {
                if controller.history.isEmpty {
                    ContentUnavailableView("还没有课堂记录", systemImage: "text.book.closed", description: Text("开始一次录课，音频与文字会自动保存在这里。"))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(filtered) { session in
                    NavigationLink { LessonDetailView(session: session) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(session.course).font(.headline)
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                            HStack {
                                Text(SessionStore.timestamp(session.duration)).monospacedDigit()
                                Text("·")
                                Text(session.state == .recovered ? "已恢复 · 请核对录音" : (session.state == .stopped ? "已保存" : "正在录课"))
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 7)
                    }
                }
            }.listStyle(.plain).navigationTitle("课堂记录")
                .searchable(text: $search, prompt: "搜索课程或日期")
                .task { await controller.refreshHistory() }
                .refreshable { await controller.refreshHistory() }
        }
    }
}

struct LessonDetailView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dismiss) private var dismiss
    @State private var session: LectureSession
    @State private var segments: [TranscriptSegment] = []
    @State private var notes: [LectureNote] = []
    @State private var page = 0
    @State private var markedOnly = false
    @State private var export = false
    @State private var error = ""
    @State private var noteContext: NoteContext?
    @StateObject private var playback = LecturePlayback()
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var resumeAfterScrub = false
    var inSheet = false
    init(session: LectureSession, inSheet: Bool = false) { _session = State(initialValue: session); self.inSheet = inSheet }
    private var filtered: [TranscriptSegment] {
        markedOnly ? segments.filter { segment in notes.contains { $0.segmentID == segment.id } } : segments
    }
    var body: some View {
        List {
            Section {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                HStack { Text(SessionStore.timestamp(session.duration)).monospacedDigit(); Spacer(); Text("英语 → 中文") }.font(.subheadline)
                if session.state == .recovered { Text("这节课在异常退出后恢复，请核对最后一段录音。原始文件已保留。").font(.footnote).foregroundStyle(.secondary) }
                if !session.usesRecordingTimeline { Text("旧版记录保留暂停空档，跳转到无音频的时段会定位到下一段录音。").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("回听课堂") {
                if playback.loading { ProgressView("正在读取录音…") }
                else if session.audioFiles.isEmpty { Text("这节课没有可播放的音频，文字稿仍可查看和导出。").foregroundStyle(.secondary) }
                else {
                    Slider(value: Binding(get: { scrubbing ? scrubValue : playback.position }, set: { scrubValue = $0 }), in: 0...max(1, playback.duration)) { editing in
                        if editing { scrubbing = true; scrubValue = playback.position; resumeAfterScrub = playback.playing; playback.pause() }
                        else { playback.seek(to: scrubValue, resume: resumeAfterScrub); scrubbing = false }
                    }.disabled(!playback.ready || controller.active).accessibilityLabel("播放位置")
                    HStack {
                        Text(SessionStore.timestamp(scrubbing ? scrubValue : playback.position))
                        Spacer(); Text(SessionStore.timestamp(playback.duration))
                    }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    HStack {
                        Button { playback.seek(to: playback.position - 15, resume: playback.playing) } label: { Image(systemName: "gobackward.15").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("后退十五秒")
                        Spacer()
                        Button { playback.toggle() } label: { Label(playback.playing ? "暂停回放" : "播放录音", systemImage: playback.playing ? "pause.fill" : "play.fill").frame(minHeight: 48) }.accessibilityIdentifier("play-lecture")
                        Spacer()
                        Button { playback.seek(to: playback.position + 15, resume: playback.playing) } label: { Image(systemName: "goforward.15").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("前进十五秒")
                    }.buttonStyle(.borderless).disabled(!playback.ready || controller.active)
                }
                if !playback.error.isEmpty { Text(playback.error).font(.footnote).foregroundStyle(.orange) }
                if controller.active { Text("录课期间暂不回放，以保护麦克风采集。").font(.footnote).foregroundStyle(.secondary) }
            }
            if !notes.isEmpty {
                Section("标记与笔记") {
                    ForEach(notes) { note in
                        Button {
                            noteContext = NoteContext(sessionID: session.id, note: note)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(SessionStore.timestamp(note.offset), systemImage: note.marked ? "bookmark.fill" : "square.and.pencil").font(.caption)
                                if !note.text.isEmpty { Text(note.text).foregroundStyle(.primary) }
                                else { Text(note.englishSnapshot.isEmpty ? "课堂标记" : note.englishSnapshot).foregroundStyle(.primary).lineLimit(2) }
                            }.padding(.vertical, 4)
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Section("文字稿") {
                Toggle("只看有标记或笔记的句子", isOn: $markedOnly).onChange(of: markedOnly) { _, _ in page = 0 }
                if filtered.isEmpty { Text(markedOnly ? "还没有标记。长按一句话，可留下笔记。" : "尚无稳定英文。音频若已保存，可先回听或导出。").foregroundStyle(.secondary) }
                ForEach(Array(filtered.dropFirst(page * 50).prefix(50))) { segment in
                    CaptionTextView(caption: WorkspaceCaption(segment), marked: notes.first { $0.segmentID == segment.id }?.marked == true)
                        .contextMenu {
                            Button("从这里播放", systemImage: "play") { playback.seek(to: segment.start, resume: true) }.disabled(controller.active || !playback.ready)
                            Button("标记 / 写笔记", systemImage: "bookmark") { edit(segment) }
                            Button("复制英文", systemImage: "doc.on.doc") { UIPasteboard.general.string = segment.english }
                            if let chinese = segment.exportChinese { Button("复制中文", systemImage: "doc.on.doc") { UIPasteboard.general.string = chinese } }
                        }
                }
                if filtered.count > 50 {
                    HStack {
                        Button("上一页") { page = max(0, page - 1) }.disabled(page == 0)
                        Spacer(); Text("\(page + 1) / \(max(1, (filtered.count + 49) / 50))").font(.caption)
                        Spacer(); Button("下一页") { page += 1 }.disabled((page + 1) * 50 >= filtered.count)
                    }.buttonStyle(.borderless).frame(minHeight: 44)
                }
            }
            Section {
                Button("补全翻译") { Task { await controller.retryTranslations(session); await load() } }.disabled(controller.busy || controller.active)
                Button("刷新记录") { Task { await load() } }
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
        }.listStyle(.insetGrouped).navigationTitle(session.course).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { export = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("导出课堂") }
                if inSheet { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            }
            .sheet(isPresented: $export) { ExportView(session: session) }
            .sheet(item: $noteContext, onDismiss: { Task { await load() } }) { NoteEditorView(context: $0) }
            .task {
                playback.recordingActive = { controller.active }
                await load()
                do { let offsets = try await controller.store.audioOffsets(session.id); await playback.prepare(session: session, folder: controller.store.folder(session.id), offsets: offsets) }
                catch { error = error.localizedDescription }
                while !Task.isCancelled && !controller.active && segments.contains(where: { $0.status == .pending && $0.error == nil }) {
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }; await load()
                }
            }
            .onDisappear { playback.stop() }
            .onChange(of: controller.active) { _, active in if active { playback.stop() } }
    }
    private func edit(_ segment: TranscriptSegment) {
        let note = notes.first { $0.segmentID == segment.id } ?? LectureNote(segmentID: segment.id, offset: segment.start, english: segment.english)
        noteContext = NoteContext(sessionID: session.id, note: note)
    }
    private func load() async {
        do {
            if let saved = try await controller.store.sessions().first(where: { $0.id == session.id }) { session = saved }
            segments = try await controller.store.segments(session.id); notes = try await controller.store.notes(session.id)
            page = min(page, max(0, (filtered.count - 1) / 50)); error = ""
        } catch { self.error = error.localizedDescription }
    }
}

struct ExportView: View {
    @EnvironmentObject private var controller: LectureController
    @Environment(\.dismiss) private var dismiss
    let session: LectureSession
    @State private var language = ExportLanguage.bilingual
    @State private var markdown = false
    @State private var audio = false
    @State private var notes = true
    @State private var diagnostics = false
    @State private var working = false
    @State private var task: Task<Void, Never>?
    @State private var files: [URL] = []
    @State private var sharing = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("文字稿") {
                    Picker("语言", selection: $language) { Text("双语").tag(ExportLanguage.bilingual); Text("英文").tag(ExportLanguage.english); Text("中文").tag(ExportLanguage.chinese) }
                    Picker("文件格式", selection: $markdown) { Text("TXT").tag(false); Text("Markdown").tag(true) }.pickerStyle(.segmented)
                    Text("优先使用 GPT 最终中文；未完成时使用完整匹配的本机中文。缺失内容会标明。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("同时带走") {
                    Toggle("标记与笔记", isOn: $notes)
                    Toggle("整节录音 · M4A", isOn: $audio).disabled(session.audioFiles.isEmpty)
                    Toggle("诊断文件", isOn: $diagnostics)
                    Text("笔记独立成文件；诊断用于检查延迟或故障。所有文件均为生成时的快照。").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(working ? "正在准备文件…" : "生成导出文件") { generate() }.disabled(working || controller.active || controller.busy)
                    if working { ProgressView("音频较长时需要一些时间…"); Button("取消导出") { task?.cancel() } }
                    if !files.isEmpty {
                        Button { sharing = true } label: { Label("分享 / 保存到文件", systemImage: "square.and.arrow.up") }.disabled(working)
                        Text("已准备 \(files.count) 个文件").font(.caption).foregroundStyle(.secondary)
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.orange).font(.footnote) }
                    if controller.active { Text("请先结束录课，等待保存完成后再导出。").font(.footnote).foregroundStyle(.secondary) }
                }
            }
                .navigationTitle("导出课堂").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { task?.cancel(); dismiss() } } }
                .sheet(isPresented: $sharing) { ActivityShareView(files: files) }
                .onDisappear { task?.cancel() }
        }
    }
    private func generate() {
        guard !working else { return }; working = true; files = []; error = ""
        let selectedLanguage = language, selectedMarkdown = markdown, includeAudio = audio, includeNotes = notes, includeDiagnostics = diagnostics
        task = Task {
            defer { working = false }
            do {
                let (text, diagnostic) = try await controller.exportText(session, language: selectedLanguage, markdown: selectedMarkdown)
                var result = [text]; try Task.checkCancellation()
                if includeNotes { result.append(try await controller.store.exportNotes(session.id, markdown: selectedMarkdown)) }
                if includeDiagnostics { result.append(diagnostic) }
                if includeAudio { result.append(try await controller.exportAudio(session)) }
                try Task.checkCancellation(); files = result
            } catch is CancellationError { error = "导出已取消，原始记录保留。" }
            catch { self.error = error.localizedDescription }
        }
    }
}
struct ActivityShareView: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: files, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
