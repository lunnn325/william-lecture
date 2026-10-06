import AVFoundation
import Speech
import WLCore
import WLAppleAudio

/// Bounded input bridge. Overflow loses live ASR input only; original audio is retained.
private final class SpeechInputBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WL.speech.convert")
    private let slots = DispatchSemaphore(value: 48)
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var target: AVAudioFormat?
    private var converter: StreamingPCMConverter?
    private var captureDates = AudioCaptureDates()
    private let onDrop: @Sendable (Double) -> Void
    private let onFailure: @Sendable (String) -> Void
    init(onDrop: @escaping @Sendable (Double) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.onDrop = onDrop; self.onFailure = onFailure
    }
    func attach(_ continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        lock.lock(); self.continuation = continuation; target = format; lock.unlock()
    }
    func offer(_ packet: AudioPacket) {
        lock.lock(); let sink = continuation; let format = target; lock.unlock()
        guard let sink, let format else { return }
        guard slots.wait(timeout: .now()) == .success else { onDrop(packet.offset); return }
        queue.async {
            defer { self.slots.signal() }
            do {
                self.lock.withLock { self.captureDates.observe(offset: packet.offset, capturedAt: packet.capturedAt) }
                if self.converter?.outputFormat != format { self.converter = StreamingPCMConverter(outputFormat: format) }
                guard let output = try self.converter?.convert(packet.buffer, capturedAt: packet.offset) else { return }
                let result = sink.yield(AnalyzerInput(buffer: output.buffer, bufferStartTime: output.start))
                if case .dropped = result { self.onDrop(packet.offset) }
            } catch {
                self.converter?.resetAfterFailure()
                self.onDrop(packet.offset)
                self.onFailure("Speech PCM conversion: \(SpeechErrorDetails.describe(error))")
            }
        }
    }
    func captureDate(at offset: Double) -> Date? { lock.withLock { captureDates.date(at: offset) } }
    func finish() async {
        let sink = lock.withLock { let sink = continuation; continuation = nil; target = nil; return sink }
        await withCheckedContinuation { done in queue.async {
            do {
                for output in try self.converter?.finish() ?? [] {
                    sink?.yield(AnalyzerInput(buffer: output.buffer, bufferStartTime: output.start))
                }
            } catch { self.onFailure("Speech PCM finalization: \(SpeechErrorDetails.describe(error))") }
            self.converter = nil; sink?.finish(); done.resume()
        } }
    }
}

@MainActor final class SpeechService {
    enum Event { case status(String), result(SpeechPiece, Bool), error(String), dropped(Double), diagnostic(String, [String: String]) }
    var onEvent: ((Event) -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private lazy var bridge = SpeechInputBridge(onDrop: { [weak self] offset in
        Task { @MainActor in self?.onEvent?(.dropped(offset)) }
    }, onFailure: { [weak self] message in Task { @MainActor in self?.onEvent?(.error(message)) } })
    /// Safe nonblocking closure installed on the audio writer queue.
    func packetSink() -> @Sendable (AudioPacket) -> Void {
        let bridge = self.bridge
        return { bridge.offer($0) }
    }

    func start(localeIdentifier: String = "en-AU") async throws {
        onEvent?(.status("检查 Apple 本机模型…"))
        let locale = Locale(identifier: localeIdentifier)
        var primaryError: String?
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            do {
                let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
                try await install(modules: [module], locale: supported)
                try Task.checkCancellation()
                try await prepare(modules: [module])
                resultsTask = Task { [weak self] in
                    do { for try await result in module.results {
                        guard !Task.isCancelled else { break }
                        self?.emit(text: String(result.text.characters), range: result.range, final: result.isFinal)
                    } } catch { if !Task.isCancelled { self?.onEvent?(.error(SpeechErrorDetails.describe(error))) } }
                }
                onEvent?(.status("SpeechTranscriber · 本机英文"))
                return
            } catch {
                try Task.checkCancellation()
                primaryError = SpeechErrorDetails.describe(error)
                onEvent?(.diagnostic("speech_primary_setup_failed", ["error": primaryError!, "locale": supported.identifier]))
                onEvent?(.status("主转写引擎未启动，尝试 Dictation…"))
            }
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            do {
                let module = DictationTranscriber(locale: supported, contentHints: [.farField], transcriptionOptions: [], reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange])
                try await install(modules: [module], locale: supported)
                try Task.checkCancellation()
                try await prepare(modules: [module])
                resultsTask = Task { [weak self] in
                    do { for try await result in module.results {
                        guard !Task.isCancelled else { break }
                        self?.emit(text: String(result.text.characters), range: result.range, final: result.isFinal)
                    } } catch { if !Task.isCancelled { self?.onEvent?(.error(SpeechErrorDetails.describe(error))) } }
                }
                onEvent?(.status("DictationTranscriber · 降级本机英文"))
                return
            } catch {
                try Task.checkCancellation()
                let fallbackError = SpeechErrorDetails.describe(error)
                throw WLFailure.message("Speech 初始化失败。\nSpeechTranscriber: \(primaryError ?? "设备/locale 不支持")\nDictationTranscriber: \(fallbackError)\n录音继续保存。")
            }
        }
        throw WLFailure.message(primaryError ?? "此设备或语言没有可用英文转写模型；录音继续")
    }
    private func install(modules: [any SpeechModule], locale: Locale) async throws {
        try Task.checkCancellation()
        // false means already reserved, which is expected on resume or the next lecture.
        // Unsupported assets / exceeding the reservation limit throw instead.
        _ = try await AssetInventory.reserve(locale: locale)
        let status = await AssetInventory.status(forModules: modules)
        onEvent?(.diagnostic("speech_asset_status", ["locale": locale.identifier, "status": String(describing: status)]))
        onEvent?(.status("英文模型：\(String(describing: status))"))
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            onEvent?(.status("下载英文模型（录音继续）…"))
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        let ready = await AssetInventory.status(forModules: modules)
        onEvent?(.diagnostic("speech_asset_ready", ["locale": locale.identifier, "status": String(describing: ready)]))
        guard case .installed = ready else { throw WLFailure.message("英文模型尚未安装可用：\(String(describing: ready))（\(locale.identifier)）") }
    }
    private func prepare(modules: [any SpeechModule]) async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { throw WLFailure.message("Apple Speech 没有可用音频格式") }
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(96))
        let analyzer = SpeechAnalyzer(modules: modules)
        onEvent?(.diagnostic("speech_analyzer_prepare", ["format": format.description]))
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        try await analyzer.start(inputSequence: stream)
        if Task.isCancelled { continuation.finish(); await analyzer.cancelAndFinishNow(); throw CancellationError() }
        self.analyzer = analyzer; bridge.attach(continuation, format: format)
    }
    private func emit(text: String, range: CMTimeRange, final: Bool) {
        let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
        guard start.isFinite, end.isFinite else { return }
        onEvent?(.result(SpeechPiece(text: text, start: start, end: end,
            audioStartedAt: bridge.captureDate(at: start), audioEndedAt: bridge.captureDate(at: end)), final))
    }
    func finish() async {
        await bridge.finish()
        if let analyzer {
            do {
                try await AsyncDeadline.run(seconds: 8) {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
            } catch {
                onEvent?(.error(SpeechErrorDetails.describe(error)))
                resultsTask?.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        }
        if let resultsTask {
            do { try await AsyncDeadline.run(seconds: 1) { await resultsTask.value } }
            catch { resultsTask.cancel(); onEvent?(.error("Speech 结果未能及时结束；原始音频已保存")) }
        }
        self.resultsTask = nil; analyzer = nil
    }
}

enum SpeechErrorDetails {
    static func describe(_ error: Error) -> String {
        var current = error as NSError
        var lines: [String] = []
        for _ in 0..<3 {
            lines.append("\(current.domain) (\(current.code)): \(current.localizedDescription)")
            if let reason = current.localizedFailureReason, !reason.isEmpty { lines.append(reason) }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return lines.joined(separator: "\n")
    }
}
