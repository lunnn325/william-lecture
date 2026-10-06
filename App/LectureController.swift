import AVFoundation
import Combine
import Foundation
import Network
import WLCore
import WLAppleAudio

@MainActor final class LectureController: ObservableObject {
    @Published var course = UserDefaults.standard.string(forKey: "selectedCourse") ?? "未分类课程"
    @Published var session: LectureSession?
    @Published var history: [LectureSession] = []
    @Published var visible: [TranscriptSegment] = []
    @Published var latestCaptionUpdate: TranscriptSegment?
    @Published var sessionNotes: [LectureNote] = []
    @Published var noteBusy = false
    @Published var savedCourses = UserDefaults.standard.stringArray(forKey: "savedCourses") ?? []
    @Published var volatileEnglish = ""
    @Published var currentChinese = ""
    @Published var audioStatus = "未录音"
    @Published var speechStatus = "未启动"
    @Published var speechError = ""
    @Published var translationStatus = "模拟模式"
    @Published var localStatus = "尚未检查本机模型"
    @Published var localEnabled = UserDefaults.standard.object(forKey: "localTranslationEnabled") as? Bool ?? true
    @Published var warning = ""
    var elapsed: Double { session?.recordingSeconds ?? 0 }
    private var timelineOffset: Double { session?.timelineOffset() ?? 0 }
    @Published var peak = 0.0
    @Published var inputRMSDBFS = -120.0
    @Published var inputPeakDBFS = -120.0
    @Published var busy = false
    @Published var mode = TranslationMode(rawValue: UserDefaults.standard.string(forKey: "translationMode") ?? "openAI") ?? .openAI
    @Published var model = UserDefaults.standard.string(forKey: "translationModel") ?? "gpt-4.1-mini"
    @Published var locale = UserDefaults.standard.string(forKey: "speechLocale") ?? "en-AU"
    let store: SessionStore
    private var recorder: AudioRecorder?
    private var speech: SpeechService?
    private var speechPreparation: Task<Void, Never>?
    private var worker: TranslationWorker?
    private var localWorker: LocalTranslationWorker?
    private let localTranslator = AppleLocalTranslator()
    private var drafts = CaptionDraftCoordinator()
    private var previewChinese: [UUID: String] = [:]
    private var focusedCaptionID: UUID?
    private var primaryCaptionVisible = false
    private var renderedRows: Set<UUID> = []
    private var displayedFinalIDs: Set<UUID> = []
    private var foreground = true
    private var buffer = SentenceBuffer()
    private var bufferFlush: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var interrupted = false
    private var lastPartialLog = Date.distantPast
    private var speechReadyAt: Double?
    private var newestDisplayEnd = -1.0
    private let network = NWPathMonitor()
    private var wasOffline = false
    private var seenSpeechResult = false
    private var interruptionTask: Task<Void, Never>?
    private var wantsRecovery = false
    private var finalCursor = FinalSpeechCursor()
    private var lastSpeechResultAt: Date?

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG
        let directory = ProcessInfo.processInfo.arguments.contains("--wl-ui-fixture") ? "UIFixture" : "Sessions"
        #else
        let directory = "Sessions"
        #endif
        store = SessionStore(root: documents.appendingPathComponent(directory, isDirectory: true))
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.prepare()
                let issues = try await store.recover()
                warning = issues.prefix(5).joined(separator: "\n")
                #if DEBUG
                if isUIFixture { try await installUIFixture() }
                #endif
                await refreshHistory()
            } catch { warning = error.localizedDescription }
        }
        network.pathUpdateHandler = { [weak self] path in Task { @MainActor in
            guard let self else { return }
            if path.status == .satisfied {
                if self.wasOffline { self.log("network_restored"); self.worker?.networkRestored() }
                self.wasOffline = false
            } else { self.wasOffline = true; self.log("network_offline") }
        } }
        network.start(queue: DispatchQueue(label: "WL.network"))
    }
    var active: Bool { session != nil && session?.state != .stopped && session?.state != .recovered }
    var recording: Bool { session?.state == .recording }
    @discardableResult func saveSettings(key: String?) -> Bool {
        guard !active else { warning = "请先结束录课，再更改翻译设置"; return false }
        if let key { do { try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)) } catch { warning = error.localizedDescription; return false } }
        UserDefaults.standard.set(mode.rawValue, forKey: "translationMode")
        UserDefaults.standard.set(model, forKey: "translationModel")
        UserDefaults.standard.set(locale, forKey: "speechLocale")
        UserDefaults.standard.set(localEnabled, forKey: "localTranslationEnabled")
        return true
    }
    func start() async {
        guard !busy, !active else { return }; busy = true; defer { busy = false }
        #if DEBUG
        if isUIFixture { await startUIFixture(); return }
        #endif
        await worker?.waitForCancellation(); worker = nil
        await localWorker?.shutdown(); localWorker = nil
        interruptionTask?.cancel(); await interruptionTask?.value; interruptionTask = nil
        await persistence?.value
        do {
            if let space = try await store.availableCapacityForRecording(), space < 500 * 1024 * 1024 { throw WLFailure.message("可用空间不足 500 MB；请清理后再录音") }
            let next = LectureSession(course: course.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名课程" : course)
            selectCourse(next.course)
            try await store.save(next)
            let folder = store.folder(next.id)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
            session = next; visible = []; buffer = SentenceBuffer(); currentChinese = ""; volatileEnglish = ""; warning = ""; newestDisplayEnd = -1; interrupted = false; wantsRecovery = false
            latestCaptionUpdate = nil; sessionNotes = []
            finalCursor = FinalSpeechCursor(); lastSpeechResultAt = nil
            drafts = CaptionDraftCoordinator(); previewChinese = [:]; focusedCaptionID = nil
            renderedRows = []; displayedFinalIDs = []
            let recorder = AudioRecorder(); self.recorder = recorder
            recorder.onEvent = { [weak self] event in Task { @MainActor in
                guard self?.session?.id == next.id else { return }
                self?.handleAudio(event)
            } }
            try await recorder.start(directory: folder, origin: next.startedAt)
            makeWorker(next); makeLocalWorker(next)
            startSpeech(); startTimer(); await refreshHistory()
        } catch {
            warning = error.localizedDescription; audioStatus = "录音未开始"
            if var failed = session { failed.state = .stopped; failed.stoppedAt = Date(); session = failed; try? await store.save(failed) }
            await recorder?.stop(); recorder = nil
        }
    }
    func pauseOrResume() async {
        guard !busy, active else { return }; busy = true; defer { busy = false }
        #if DEBUG
        if isUIFixture { session?.state = recording ? .paused : .recording; if let session { try? await store.save(session) }; return }
        #endif
        if recording {
            await recorder?.pause(); session?.state = .paused
            await snapshotRecordingDuration()
            await finishSpeech(); flushBuffer(); invalidateDraft(); await persistence?.value
            audioStatus = "已暂停；音频已保存"
            log("pause", gap: "用户课间暂停，未采集此时段音频")
        } else {
            do {
                try await recorder?.resume(); session?.state = .recording; interrupted = false
                startSpeech(); log("resume")
            } catch { warning = error.localizedDescription; audioStatus = "恢复录音失败" }
        }
        if let session { try? await store.save(session) }
    }
    func stop() async {
        guard !busy, active else { return }; busy = true; defer { busy = false }
        #if DEBUG
        if isUIFixture { session?.state = .stopped; session?.stoppedAt = Date(); if let session { try? await store.save(session) }; await refreshHistory(); return }
        #endif
        // Stop/close the audio first; never wait for translation to stop recording.
        await recorder?.stop(); recorder?.onPacket = nil
        let stoppedAt = Date()
        await snapshotRecordingDuration()
        timer?.cancel(); timer = nil
        session?.state = .stopped // Reject late interruption events while draining Speech.
        await finishSpeech(); flushBuffer(); invalidateDraft(); await persistence?.value
        if var ended = session {
            ended.state = .stopped; ended.stoppedAt = stoppedAt
            ended.duration = ended.usesRecordingTimeline ? ended.recordingSeconds : stoppedAt.timeIntervalSince(ended.startedAt)
            session = ended
            do { try await store.save(ended); try await store.log(Diagnostic("session_stop", offset: ended.duration), session: ended.id) }
            catch { warning = "保存记录失败：\(error.localizedDescription)" }
        }
        timer?.cancel(); timer = nil; recorder = nil; audioStatus = "已停止；翻译可继续补齐"
        await refreshHistory()
    }
    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let session = self.session else { return }
                self.session?.duration = session.timelineOffset()
            }
        }
    }
    private func startSpeech() {
        invalidateDraft()
        let preparationStart = timelineOffset
        speechReadyAt = nil
        seenSpeechResult = false
        speechError = ""
        let service = SpeechService(); speech = service
        service.onEvent = { [weak self, weak service] event in
            guard let self, let service, self.speech === service else { return }
            self.handleSpeech(event)
        }
        recorder?.onPacket = service.packetSink()
        let id = session?.id
        speechPreparation = Task { [weak self, weak service] in
            guard let self, let service else { return }
            do {
                try await service.start(localeIdentifier: self.locale)
                guard !Task.isCancelled, self.session?.id == id else { await service.finish(); return }
                let ready = self.timelineOffset; self.speechReadyAt = ready
                self.log("speech_ready", fields: ["engine": self.speechStatus, "locale": self.locale])
                if ready - preparationStart > 1 { self.log("speech_preparation_gap", gap: "模型准备期间只录音，未实时转写；音频保留可补处理") }
            } catch is CancellationError { }
            catch {
                guard self.speech === service, self.session?.id == id, !Task.isCancelled else { return }
                self.speechStatus = "转写不可用；录音继续"
                self.speechError = SpeechErrorDetails.describe(error)
                self.log("speech_error", fields: ["error": self.speechError], gap: "实时英文可能缺失；原始音频继续保存")
            }
        }
    }
    private func finishSpeech() async {
        localWorker?.clearDraft()
        speechPreparation?.cancel()
        // Do not await a model download that might outlive cancellation. Prepared analyzers are drained.
        recorder?.onPacket = nil
        await speech?.finish(); speech?.onEvent = nil; speech = nil; speechPreparation = nil; speechStatus = "转写已停止"
    }
    private func handleSpeech(_ event: SpeechService.Event) {
        guard let session else { return }
        switch event {
        case .status(let status): speechStatus = status
        case .error(let message): speechStatus = "转写错误；录音继续"; speechError = message; log("speech_error", fields: ["error": message], gap: "英文转写中断，音频保留")
        case .diagnostic(let event, let fields): log(event, fields: fields)
        case .dropped(let offset): log("speech_input_drop", offset: offset, gap: "Speech 输入积压或转换失败；音频未丢失")
        case .result(let piece, let final):
            lastSpeechResultAt = piece.receivedAt
            if !seenSpeechResult {
                seenSpeechResult = true
                log("speech_first_result", offset: piece.end, fields: speechTiming(piece, session: session))
            }
            if !final {
                volatileEnglish = piece.text
                if localEnabled && recording && foreground {
                    drafts.replacePartial(piece); refreshDraft()
                }
                if Date().timeIntervalSince(lastPartialLog) >= 1 {
                    lastPartialLog = Date()
                    var fields = speechTiming(piece, session: session)
                    if let draft = drafts.current { fields["segment"] = draft.id.uuidString; fields["revision"] = "\(draft.revision)" }
                    log("speech_partial", offset: piece.end, fields: fields)
                }
            } else {
                let previousEnd = finalCursor.end
                guard finalCursor.accept(piece) else { return }
                if piece.start < previousEnd - 0.01 {
                    log("speech_final_overlap", offset: piece.end, fields: ["previous_end": "\(previousEnd)", "range_start": "\(piece.start)"])
                }
                volatileEnglish = ""
                drafts.acceptedFinal(piece)
                enqueue { try await self.store.appendFinal(piece, session: session.id) }
                log("speech_finalized", offset: piece.end, fields: speechTiming(piece, session: session))
                if let segment = buffer.append(piece) { persistSegment(segment) }
                refreshDraft()
                scheduleBufferFlush()
            }
        }
    }
    private func persistSegment(_ segment: TranscriptSegment) {
        guard let id = session?.id else { return }
        if drafts.current == nil { focusedCaptionID = segment.id }
        if localEnabled, let draft = drafts.current, draft.id == segment.id, let chinese = draft.chinese { previewChinese[segment.id] = chinese }
        var segment = drafts.freeze(segment)
        segment.localEnabled = localEnabled; segment.gptDeferred = worker == nil
        segment.queuedAt = Date()
        let emittedAt = segment.queuedAt!
        updateVisible(segment)
        enqueue {
            try await self.store.append(segment, session: id)
            self.worker?.kick()
            self.localWorker?.kick()
            try await self.store.log(Diagnostic("buffer_emit", offset: segment.end, fields: ["segment": segment.id.uuidString, "english_final_to_emit_ms": "\(Int(emittedAt.timeIntervalSince(segment.receivedAt) * 1000))"], at: emittedAt), session: id)
        }
    }
    private func scheduleBufferFlush() {
        bufferFlush?.cancel(); bufferFlush = nil
        guard let deadline = buffer.quietDeadline else { return }
        bufferFlush = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            if let segment = self.buffer.flushIfQuiet(now: Date()) { self.persistSegment(segment); self.refreshDraft() }
        }
    }
    private func flushBuffer() {
        bufferFlush?.cancel(); bufferFlush = nil
        if let segment = buffer.flush() { persistSegment(segment) }
    }
    private func makeWorker(_ session: LectureSession) {
        let config = TranslatorConfiguration(mock: mode == .mock, model: model, key: Keychain.load())
        if !config.mock && (config.key?.isEmpty ?? true) {
            worker = nil; translationStatus = "GPT 未配置；本机中文/英文/录音可继续"; return
        }
        let worker = TranslationWorker(store: store, config: config, session: session)
        worker.onUpdate = { [weak self, weak worker] segment in
            guard let worker, self?.worker === worker, self?.session?.id == session.id else { return }
            self?.updateVisible(segment)
        }
        worker.onState = { [weak self, weak worker] state in
            guard let worker, self?.worker === worker else { return }
            self?.translationStatus = state
        }
        worker.hasDraft = { [weak self] id in self?.previewChinese[id] != nil }
        self.worker = worker
    }
    private func updateVisible(_ segment: TranscriptSegment) {
        var segment = segment
        let prior = visible.first(where: { $0.id == segment.id })
        if let prior { segment = segment.mergingDisplay(prior) }
        latestCaptionUpdate = segment
        if segment.finalChinese != nil || segment.validLocalChinese != nil { previewChinese.removeValue(forKey: segment.id) }
        if let index = visible.firstIndex(where: { $0.id == segment.id }) { visible[index] = segment }
        else { visible.append(segment); visible.sort { $0.start < $1.start }; if visible.count > 30 { visible.removeFirst(visible.count - 30) } }
        let primary = focusedCaptionID == segment.id || (focusedCaptionID == nil && segment.end >= newestDisplayEnd)
        if primary, let chinese = captionChinese(segment) {
            newestDisplayEnd = segment.end; currentChinese = chinese
        } else if primary && (segment.status == .failed || segment.error != nil) {
            currentChinese = ""
        }
        let retained = Set(visible.map(\.id)).union([buffer.pendingID])
        previewChinese = previewChinese.filter { retained.contains($0.key) }
        renderedRows.formIntersection(retained); displayedFinalIDs.formIntersection(retained)
    }
    func captionChinese(_ segment: TranscriptSegment) -> String? {
        segment.finalChinese ?? segment.validLocalChinese ?? previewChinese[segment.id] ?? segment.displayChinese
    }
    var captionReferenceID: UUID? { focusedCaptionID ?? visible.last?.id }
    var workspaceDraft: WorkspaceCaption? {
        guard active else { return nil }
        if let draft = drafts.current, !visible.contains(where: { $0.id == draft.id }) {
            return WorkspaceCaption(id: draft.id, start: draft.start, english: draft.english, chinese: draft.chinese, provisional: true)
        }
        let english = [buffer.pendingText, volatileEnglish].filter { !$0.isEmpty }.joined(separator: " ")
        guard !english.isEmpty, !visible.contains(where: { $0.id == buffer.pendingID }) else { return nil }
        return WorkspaceCaption(id: buffer.pendingID, start: buffer.pendingStart ?? elapsed, english: english, chinese: nil, provisional: true)
    }
    var courseChoices: [String] { Array(Set(savedCourses + history.map(\.course) + [course])).sorted() }
    func selectCourse(_ name: String) {
        guard !active else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if course != String(name.prefix(80)) {
            session = nil; visible = []; currentChinese = ""; volatileEnglish = ""; sessionNotes = []; latestCaptionUpdate = nil
        }
        course = String(name.prefix(80))
        if !savedCourses.contains(course) { savedCourses.append(course) }
        UserDefaults.standard.set(course, forKey: "selectedCourse")
        UserDefaults.standard.set(savedCourses, forKey: "savedCourses")
    }
    func latestWorkspaceRows() async -> [TranscriptSegment] {
        guard let selected = session else { return [] }
        do {
            let records = try await store.segments(selected.id)
            guard session?.id == selected.id else { return [] }
            var feed = CaptionFeed(); feed.merge(Array(records.suffix(180))); feed.merge(visible)
            return feed.rows
        } catch { warning = error.localizedDescription; return visible }
    }
    func note(for id: UUID) -> LectureNote? { sessionNotes.first { $0.segmentID == id } }
    func writeNote(_ note: LectureNote, session id: UUID) async -> Bool {
        guard !noteBusy else { return false }; noteBusy = true; defer { noteBusy = false }
        do {
            var saved = note; saved.updatedAt = Date(); try await store.saveNote(saved, session: id)
            let notes = try await store.notes(id)
            if session?.id == id { sessionNotes = notes }
            return true
        } catch { warning = "笔记保存失败：\(error.localizedDescription)"; return false }
    }
    func toggleMark(_ caption: WorkspaceCaption) async {
        guard let id = session?.id else { return }
        var note = note(for: caption.id) ?? LectureNote(segmentID: caption.id, offset: caption.start, english: caption.english, marked: false)
        note.marked.toggle(); _ = await writeNote(note, session: id)
    }
    func setPrimaryCaptionVisible(_ value: Bool) {
        primaryCaptionVisible = value
        if value, let id = captionReferenceID { captionDidRender(id: id) }
    }
    func setRowVisible(_ id: UUID, _ value: Bool) {
        if value { renderedRows.insert(id); captionDidRender(id: id) }
        else { renderedRows.remove(id) }
    }
    /// Called by visible SwiftUI captions, rather than by model completion callbacks.
    func captionDidRender(id: UUID) {
        let primary = captionReferenceID == id && primaryCaptionVisible
        guard foreground, primary || renderedRows.contains(id) else { return }
        let at = Date()
        if let draft = drafts.current, draft.id == id, drafts.markDisplayed(id: id, at: at) {
            log("local_first_display", offset: draft.end, fields: ["segment": id.uuidString,
                "revision": "\(draft.revision)", "mock": "\(mode == .mock)",
                "partial_to_display_ms": "\(Int(max(0, at.timeIntervalSince(draft.firstPartialAt)) * 1000))"])
        }
        guard let index = visible.firstIndex(where: { $0.id == id }), let classroom = session?.id else { return }
        var segment = visible[index]
        if segment.finalChinese == nil && (segment.validLocalChinese != nil || previewChinese[id] != nil) && segment.localDisplayedAt == nil {
            segment.localDisplayedAt = at; visible[index] = segment
            log("local_first_display", offset: segment.end, fields: ["segment": id.uuidString, "revision": "\(segment.sourceRevision)",
                "mock": "\(mode == .mock)", "partial_to_display_ms": "\(Int(max(0, at.timeIntervalSince(segment.partialFirstAt ?? segment.receivedAt)) * 1000))"])
            let source = segment; enqueue { try await self.store.markLocalDisplayed(source, session: classroom, at: at) }
        }
        if segment.finalChinese != nil, displayedFinalIDs.insert(id).inserted {
            var fields = ["segment": id.uuidString, "revision": "\(segment.sourceRevision)", "primary": "\(primary)", "mock": "\(mode == .mock)"]
            if let displayed = segment.localDisplayedAt {
                fields["local_to_gpt_ms"] = "\(Int(max(0, at.timeIntervalSince(displayed)) * 1000))"
                log("caption_gpt_replaced", offset: segment.end, fields: fields)
            } else { fields["local_shown"] = "false"; log("caption_gpt_displayed", offset: segment.end, fields: fields) }
        }
    }
    var captionStatus: String {
        if let draft = drafts.current { return draft.phase.rawValue }
        return visible.last?.phase.rawValue ?? "等待英文"
    }
    func checkLocalModels() async {
        guard !active else { return }
        if mode == .mock { localStatus = "MOCK 本机译者；仅测试调度，不验证 Apple 模型"; return }
        localStatus = "正在检查英文 → 简体中文模型…"
        switch await localTranslator.availability() {
        case .installed: localStatus = "本机模型已安装，可开始录课"
        case .supported: localStatus = "需要准备语言模型；请在录课前点击准备"
        case .unsupported: localStatus = "此设备/系统不支持本机翻译；使用 GPT"
        @unknown default: localStatus = "模型状态未知；使用 GPT"
        }
    }
    private func makeLocalWorker(_ selected: LectureSession) {
        guard localEnabled else { localStatus = "已关闭"; return }
        let provider = localTranslator
        let mock = mode == .mock
        let local = LocalTranslationWorker(store: store, session: selected.id, mock: mock, operation: { text in
            if mock { try await Task.sleep(for: .milliseconds(80)); return "[MOCK 本机] \(text)" }
            return try await provider.translate(text)
        }, cancelOperation: { if !mock { await provider.cancel() } })
        local.onDraft = { [weak self, weak local] request, text, at in
            guard let self, let local, self.localWorker === local, self.session?.id == request.sessionID,
                  self.recording, self.foreground else { return .stale }
            let accepted = self.drafts.accept(request, text: text, at: at)
            guard accepted != .stale, let draft = self.drafts.current else { return .stale }
            self.focusedCaptionID = draft.id; self.currentChinese = draft.chinese ?? self.currentChinese
            self.localStatus = "本机中文已显示；等待稳定英文/GPT"
            return accepted
        }
        local.onUpdate = { [weak self, weak local] segment in
            guard let local, self?.localWorker === local, self?.session?.id == selected.id else { return }
            self?.updateVisible(segment)
        }
        local.onState = { [weak self, weak local] state in
            guard let local, self?.localWorker === local else { return }
            self?.localStatus = state
        }
        localWorker = local; local.setForeground(foreground)
        localStatus = mock ? "MOCK 本机译者" : "仅使用已安装模型；录课期间不下载"
    }
    private func refreshDraft() {
        guard localEnabled else { return }
        let previous = drafts.current?.id
        drafts.refresh(buffer: buffer, finalizedEnd: finalCursor.end)
        if let draft = drafts.current {
            focusedCaptionID = draft.id
            if let chinese = draft.chinese { currentChinese = chinese }
            else if previous != draft.id { currentChinese = "" }
            if recording && foreground, let id = session?.id, let request = drafts.request(session: id) { localWorker?.offer(request) }
        } else {
            localWorker?.clearDraft()
            if let previous, focusedCaptionID == previous, !visible.contains(where: { $0.id == previous }) {
                focusedCaptionID = visible.last?.id; currentChinese = visible.last.flatMap { captionChinese($0) } ?? ""
            }
        }
    }
    private func invalidateDraft() {
        drafts.invalidate(); localWorker?.clearDraft()
        if let focusedCaptionID, !visible.contains(where: { $0.id == focusedCaptionID }) {
            self.focusedCaptionID = visible.last?.id; currentChinese = visible.last.flatMap { captionChinese($0) } ?? ""
        }
    }
    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value; localWorker?.setForeground(value)
        if !value { invalidateDraft() }
        else {
            focusedCaptionID = visible.last?.id
            // A result completed in the background was never actually displayed there.
            for segment in visible { updateVisible(segment) }
            refreshDraft()
            if let id = captionReferenceID { captionDidRender(id: id) }
            for id in renderedRows { captionDidRender(id: id) }
        }
        log(value ? "caption_foreground" : "caption_background")
    }
    func retryLocalTranslation() async {
        guard localEnabled, let selected = session else { return }
        await localWorker?.shutdown(); localWorker = nil
        do { try await store.resetLocalFailures(selected.id); makeLocalWorker(selected); localWorker?.kick() }
        catch { localStatus = error.localizedDescription }
    }
    private func handleAudio(_ event: AudioRecorder.Event) {
        guard let session else { return }
        switch event {
        case .started(let offset): audioStatus = "持续本地录音"; log("audio_start", offset: offset)
        case .chunk(let name, let offset):
            if !self.session!.audioFiles.contains(name) { self.session?.audioFiles.append(name) }
            if let snapshot = self.session { enqueue { try await self.store.save(snapshot) } }
            log("audio_chunk", offset: offset, fields: ["file": name])
        case .paused: break
        case .stopped: break
        case .configuration(let fields): log("audio_input_configuration", fields: fields)
        case .metadataWarning(let message): warning = message; log("audio_index_error", fields: ["error": message])
        case .meter(let offset, let levels, let memory, let capturedSeconds, let size):
            self.peak = levels.peak; inputRMSDBFS = levels.rmsDBFS; inputPeakDBFS = levels.peakDBFS
            self.session?.updateRecordingDuration(capturedSeconds)
            log("health", offset: offset, fields: ["resident_bytes": "\(memory)", "audio_bytes": "\(size)", "captured_seconds": "\(capturedSeconds)",
                "peak": "\(levels.peak)", "input_peak_dbfs": "\(levels.peakDBFS)", "input_rms_dbfs": "\(levels.rmsDBFS)", "clipped_fraction": "\(levels.clippedFraction)",
                "speech_result_age_seconds": "\(Date().timeIntervalSince(lastSpeechResultAt ?? session.startedAt))"])
        case .interrupted(let offset, _):
            guard active else { return }
            interrupted = true; self.session?.state = .interrupted; audioStatus = "系统中断；已保存音频"
            log("interruption", offset: offset, gap: "系统中断期间未采集音频")
            settleInterruption()
        case .recoveryRequested:
            guard active else { return }
            log("recovery_requested")
            wantsRecovery = true
            if interrupted && !busy && interruptionTask == nil { Task { wantsRecovery = false; await pauseOrResume() } }
        case .routeChanged: log("audio_route_change", fields: ["route": AVAudioSession.sharedInstance().currentRoute.description])
        case .failure(let message, let offset):
            guard active else { return }
            warning = "录音故障：\(message)"; audioStatus = "录音已停止，需要处理"; self.session?.state = .interrupted; interrupted = false
            log("audio_error", offset: offset, fields: ["error": message], gap: "录音写盘失败，后续音频未采集")
            settleInterruption()
        }
    }
    private func settleInterruption() {
        guard interruptionTask == nil else { return }
        let id = session?.id
        interruptionTask = Task {
            // Serialize against a user pause/stop/start already in progress.
            while busy && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled, active, session?.id == id else { interruptionTask = nil; return }
            busy = true
            await snapshotRecordingDuration()
            await finishSpeech(); flushBuffer(); invalidateDraft(); await persistence?.value
            if let snapshot = self.session { try? await store.save(snapshot) }
            busy = false; interruptionTask = nil
            if wantsRecovery && interrupted { wantsRecovery = false; await pauseOrResume() }
        }
    }
    private func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
        let previous = persistence
        persistence = Task { await previous?.value; do { try await action() } catch { warning = "文字/诊断写盘失败：\(error.localizedDescription)；请检查空间" } }
    }
    private func snapshotRecordingDuration() async {
        guard let recorder else { return }
        let seconds = await recorder.recordedDuration()
        session?.updateRecordingDuration(seconds)
    }
    private func speechTiming(_ piece: SpeechPiece, session: LectureSession) -> [String: String] {
        var fields = ["range_start": "\(piece.start)", "range_end": "\(piece.end)"]
        let startDate = piece.audioStartedAt ?? (session.usesRecordingTimeline ? nil : session.startedAt.addingTimeInterval(piece.start))
        let endDate = piece.audioEndedAt ?? (session.usesRecordingTimeline ? nil : session.startedAt.addingTimeInterval(piece.end))
        if let startDate { fields["range_start_to_receipt_ms"] = "\(Int(max(0, piece.receivedAt.timeIntervalSince(startDate)) * 1000))" }
        if let endDate {
            let milliseconds = "\(Int(max(0, piece.receivedAt.timeIntervalSince(endDate)) * 1000))"
            fields["range_end_to_receipt_ms"] = milliseconds; fields["end_to_receipt_ms"] = milliseconds
        }
        return fields
    }
    private func log(_ event: String, offset: Double? = nil, fields: [String: String] = [:], gap: String? = nil) {
        guard let id = session?.id else { return }
        var fields = fields; if let gap { fields["gap"] = gap }
        if session?.usesRecordingTimeline == true {
            fields["timeline"] = SessionTimeline.recordedAudio.rawValue
            fields["wall_offset"] = "\(Date().timeIntervalSince(session!.startedAt))"
        }
        let item = Diagnostic(event, offset: offset ?? timelineOffset, fields: fields)
        enqueue { try await self.store.log(item, session: id) }
    }
    func refreshHistory() async { do { history = try await store.sessions() } catch { warning = error.localizedDescription } }
    func retryTranslations(_ selected: LectureSession) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        guard !active || selected.id == session?.id else { warning = "录音期间只能补当前课堂"; return }
        await worker?.waitForCancellation()
        do {
            try await store.requeueGPT(selected.id, includeMock: mode == .openAI)
            makeWorker(selected); worker?.kick()
            await localWorker?.shutdown(); localWorker = nil
            if localEnabled {
                try await store.resetLocalFailures(selected.id); makeLocalWorker(selected); localWorker?.kick()
            }
        } catch { warning = error.localizedDescription }
    }
    func cancelTranslations() { worker?.cancel() }
    func exportText(_ selected: LectureSession, language: ExportLanguage, markdown: Bool) async throws -> (URL, URL) {
        guard !active, !busy else { throw WLFailure.message("请先停止录音并等待保存完成，再导出") }
        busy = true; defer { busy = false }
        await persistence?.value; await worker?.flushDiagnostics()
        await localWorker?.flushDiagnostics()
        return (try await store.export(selected.id, language: language, markdown: markdown),
                try await store.exportDiagnostics(selected.id))
    }
    func exportAudio(_ selected: LectureSession) async throws -> URL {
        guard !active, !busy else { throw WLFailure.message("请先停止录音并等待保存完成，再导出") }
        busy = true; defer { busy = false }
        await persistence?.value
        guard let saved = try await store.sessions().first(where: { $0.id == selected.id }) else { throw WLFailure.message("课堂不存在") }
        let offsets = try await store.audioOffsets(saved.id)
        let folder = store.folder(saved.id)
        let chunks = saved.audioFiles.map { AudioExportChunk(url: folder.appendingPathComponent($0), start: offsets[$0]) }
        let directory = folder.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await AudioExporter.m4a(chunks: chunks, destination: directory.appendingPathComponent("WilliamLecture-\(UUID().uuidString).m4a"), preservingGaps: !saved.usesRecordingTimeline)
    }
    func retrySpeech() async {
        guard recording, !busy else { return }; busy = true; defer { busy = false }
        await finishSpeech(); flushBuffer(); await persistence?.value
        guard recording else { return }
        log("speech_manual_retry", gap: "重启 Speech 期间只录音，实时英文可能缺失")
        startSpeech()
    }
}
