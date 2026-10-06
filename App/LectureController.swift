import AVFoundation
import Combine
import Foundation
import Network
import WLCore
import WLAppleAudio

@MainActor final class LectureController: ObservableObject {
    @Published var course = "课堂测试"
    @Published var session: LectureSession?
    @Published var history: [LectureSession] = []
    @Published var visible: [TranscriptSegment] = []
    @Published var volatileEnglish = ""
    @Published var currentChinese = ""
    @Published var audioStatus = "未录音"
    @Published var speechStatus = "未启动"
    @Published var speechError = ""
    @Published var translationStatus = "模拟模式"
    @Published var warning = ""
    var elapsed: Double { session?.recordingSeconds ?? 0 }
    private var timelineOffset: Double { session?.timelineOffset() ?? 0 }
    @Published var peak = 0.0
    @Published var inputRMSDBFS = -120.0
    @Published var inputPeakDBFS = -120.0
    @Published var busy = false
    @Published var mode = TranslationMode(rawValue: UserDefaults.standard.string(forKey: "translationMode") ?? "mock") ?? .mock
    @Published var model = UserDefaults.standard.string(forKey: "translationModel") ?? "gpt-4.1-mini"
    @Published var locale = UserDefaults.standard.string(forKey: "speechLocale") ?? "en-AU"
    let store: SessionStore
    private var recorder: AudioRecorder?
    private var speech: SpeechService?
    private var speechPreparation: Task<Void, Never>?
    private var worker: TranslationWorker?
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
        store = SessionStore(root: documents.appendingPathComponent("Sessions", isDirectory: true))
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.prepare()
                let issues = try await store.recover()
                warning = issues.prefix(5).joined(separator: "\n")
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
    func saveSettings(key: String?) {
        UserDefaults.standard.set(mode.rawValue, forKey: "translationMode")
        UserDefaults.standard.set(model, forKey: "translationModel")
        UserDefaults.standard.set(locale, forKey: "speechLocale")
        if let key { do { try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)) } catch { warning = error.localizedDescription } }
    }
    func start() async {
        guard !busy, !active else { return }; busy = true; defer { busy = false }
        await worker?.waitForCancellation(); worker = nil
        interruptionTask?.cancel(); await interruptionTask?.value; interruptionTask = nil
        await persistence?.value
        do {
            if let space = try await store.availableCapacityForRecording(), space < 500 * 1024 * 1024 { throw WLFailure.message("可用空间不足 500 MB；请清理后再录音") }
            let next = LectureSession(course: course.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名课程" : course)
            try await store.save(next)
            let folder = store.folder(next.id)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
            session = next; visible = []; buffer = SentenceBuffer(); currentChinese = ""; volatileEnglish = ""; warning = ""; newestDisplayEnd = -1; interrupted = false; wantsRecovery = false
            finalCursor = FinalSpeechCursor(); lastSpeechResultAt = nil
            let recorder = AudioRecorder(); self.recorder = recorder
            recorder.onEvent = { [weak self] event in Task { @MainActor in
                guard self?.session?.id == next.id else { return }
                self?.handleAudio(event)
            } }
            try await recorder.start(directory: folder, origin: next.startedAt)
            makeWorker(next)
            startSpeech(); startTimer(); await refreshHistory()
        } catch {
            warning = error.localizedDescription; audioStatus = "录音未开始"
            if var failed = session { failed.state = .stopped; failed.stoppedAt = Date(); session = failed; try? await store.save(failed) }
            await recorder?.stop(); recorder = nil
        }
    }
    func pauseOrResume() async {
        guard !busy, active else { return }; busy = true; defer { busy = false }
        if recording {
            await recorder?.pause(); session?.state = .paused
            await snapshotRecordingDuration()
            await finishSpeech(); flushBuffer(); await persistence?.value
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
        // Stop/close the audio first; never wait for translation to stop recording.
        await recorder?.stop(); recorder?.onPacket = nil
        let stoppedAt = Date()
        await snapshotRecordingDuration()
        timer?.cancel(); timer = nil
        session?.state = .stopped // Reject late interruption events while draining Speech.
        await finishSpeech(); flushBuffer(); await persistence?.value
        if var ended = session {
            ended.state = .stopped; ended.stoppedAt = stoppedAt; ended.duration = stoppedAt.timeIntervalSince(ended.startedAt)
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
                if ready > 1 { self.log("speech_preparation_gap", gap: "模型准备期间只录音，未实时转写；音频保留可补处理") }
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
                log("speech_first_result", offset: piece.end, fields: ["range_start_to_receipt_ms": "\(Int(piece.receivedAt.timeIntervalSince(session.startedAt.addingTimeInterval(piece.start)) * 1000))", "range_end_to_receipt_ms": "\(Int(piece.receivedAt.timeIntervalSince(session.startedAt.addingTimeInterval(piece.end)) * 1000))"])
            }
            if !final {
                volatileEnglish = piece.text
                if Date().timeIntervalSince(lastPartialLog) >= 1 {
                    lastPartialLog = Date()
                    log("speech_partial", offset: piece.end, fields: ["range_start": "\(piece.start)", "range_end": "\(piece.end)", "end_to_receipt_ms": "\(Int(piece.receivedAt.timeIntervalSince(session.startedAt.addingTimeInterval(piece.end)) * 1000))"])
                }
            } else {
                let previousEnd = finalCursor.end
                guard finalCursor.accept(piece) else { return }
                if piece.start < previousEnd - 0.01 {
                    log("speech_final_overlap", offset: piece.end, fields: ["previous_end": "\(previousEnd)", "range_start": "\(piece.start)"])
                }
                volatileEnglish = ""
                enqueue { try await self.store.appendFinal(piece, session: session.id) }
                log("speech_finalized", offset: piece.end, fields: ["range_start": "\(piece.start)", "range_end": "\(piece.end)", "end_to_receipt_ms": "\(Int(piece.receivedAt.timeIntervalSince(session.startedAt.addingTimeInterval(piece.end)) * 1000))"])
                if let segment = buffer.append(piece) { persistSegment(segment) }
                scheduleBufferFlush()
            }
        }
    }
    private func persistSegment(_ segment: TranscriptSegment) {
        guard let id = session?.id else { return }
        var segment = segment
        segment.queuedAt = Date()
        let emittedAt = segment.queuedAt!
        updateVisible(segment)
        enqueue {
            try await self.store.append(segment, session: id)
            self.worker?.kick()
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
            if let segment = self.buffer.flushIfQuiet(now: Date()) { self.persistSegment(segment) }
        }
    }
    private func flushBuffer() {
        bufferFlush?.cancel(); bufferFlush = nil
        if let segment = buffer.flush() { persistSegment(segment) }
    }
    private func makeWorker(_ session: LectureSession) {
        let config = TranslatorConfiguration(mock: mode == .mock, model: model, key: Keychain.load())
        let worker = TranslationWorker(store: store, config: config, session: session)
        worker.onUpdate = { [weak self] segment in
            guard self?.session?.id == session.id else { return }
            self?.updateVisible(segment)
        }
        worker.onState = { [weak self, weak worker] state in
            guard let worker, self?.worker === worker else { return }
            self?.translationStatus = state
        }
        self.worker = worker
    }
    private func updateVisible(_ segment: TranscriptSegment) {
        if let index = visible.firstIndex(where: { $0.id == segment.id }) { visible[index] = segment }
        else { visible.append(segment); visible.sort { $0.start < $1.start }; if visible.count > 30 { visible.removeFirst(visible.count - 30) } }
        if segment.end >= newestDisplayEnd, let chinese = segment.chinese {
            newestDisplayEnd = segment.end; currentChinese = chinese
        }
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
            await finishSpeech(); flushBuffer(); await persistence?.value
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
    private func log(_ event: String, offset: Double? = nil, fields: [String: String] = [:], gap: String? = nil) {
        guard let id = session?.id else { return }
        var fields = fields; if let gap { fields["gap"] = gap }
        let item = Diagnostic(event, offset: offset ?? timelineOffset, fields: fields)
        enqueue { try await self.store.log(item, session: id) }
    }
    func refreshHistory() async { do { history = try await store.sessions() } catch { warning = error.localizedDescription } }
    func retryTranslations(_ selected: LectureSession) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        guard !active || selected.id == session?.id else { warning = "录音期间只能补当前课堂"; return }
        await worker?.waitForCancellation()
        do {
            for var segment in try await store.segments(selected.id) where segment.status == .failed || (mode == .openAI && segment.status == .mock) {
                segment.status = .pending; segment.error = nil; try await store.append(segment, session: selected.id)
            }
            makeWorker(selected); worker?.kick()
        } catch { warning = error.localizedDescription }
    }
    func cancelTranslations() { worker?.cancel() }
    func exportText(_ selected: LectureSession, language: ExportLanguage, markdown: Bool) async throws -> (URL, URL) {
        guard !active, !busy else { throw WLFailure.message("请先停止录音并等待保存完成，再导出") }
        busy = true; defer { busy = false }
        await persistence?.value; await worker?.flushDiagnostics()
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
        return try await AudioExporter.m4a(chunks: chunks, destination: directory.appendingPathComponent("WilliamLecture-\(UUID().uuidString).m4a"))
    }
    func retrySpeech() async {
        guard recording, !busy else { return }; busy = true; defer { busy = false }
        await finishSpeech(); flushBuffer(); await persistence?.value
        guard recording else { return }
        log("speech_manual_retry", gap: "重启 Speech 期间只录音，实时英文可能缺失")
        startSpeech()
    }
}
