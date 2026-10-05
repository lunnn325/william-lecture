import AVFoundation
import Speech
import WLCore

/// Bounded input bridge. Overflow loses live ASR input only; original audio is retained.
private final class SpeechInputBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WL.speech.convert")
    private let slots = DispatchSemaphore(value: 48)
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var target: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let onDrop: @Sendable (Double) -> Void
    init(onDrop: @escaping @Sendable (Double) -> Void) { self.onDrop = onDrop }
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
                let output: AVAudioPCMBuffer
                if packet.buffer.format == format { output = packet.buffer }
                else {
                    if self.converter?.inputFormat != packet.buffer.format {
                        self.converter = AVAudioConverter(from: packet.buffer.format, to: format)
                    }
                    guard let converter = self.converter,
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(packet.buffer.frameLength) * format.sampleRate / packet.buffer.format.sampleRate) + 64))
                    else { throw WLFailure.message("Speech audio converter unavailable") }
                    var supplied = false; var error: NSError?
                    let result = converter.convert(to: buffer, error: &error) { _, status in
                        if supplied { status.pointee = .noDataNow; return nil }
                        supplied = true; status.pointee = .haveData; return packet.buffer
                    }
                    if let error { throw error }
                    guard result != .error, buffer.frameLength > 0 else { return }
                    output = buffer
                }
                let result = sink.yield(AnalyzerInput(buffer: output, bufferStartTime: CMTime(seconds: packet.offset, preferredTimescale: 48_000)))
                if case .dropped = result { self.onDrop(packet.offset) }
            } catch { self.onDrop(packet.offset) }
        }
    }
    func finish() async {
        lock.lock(); let sink = continuation; continuation = nil; target = nil; lock.unlock()
        await withCheckedContinuation { done in queue.async { self.converter = nil; sink?.finish(); done.resume() } }
    }
}

@MainActor final class SpeechService {
    enum Event { case status(String), result(SpeechPiece, Bool), error(String), dropped(Double) }
    var onEvent: ((Event) -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private lazy var bridge = SpeechInputBridge { [weak self] offset in Task { @MainActor in self?.onEvent?(.dropped(offset)) } }
    /// Safe nonblocking closure installed on the audio writer queue.
    func packetSink() -> @Sendable (AudioPacket) -> Void {
        let bridge = self.bridge
        return { bridge.offer($0) }
    }

    func start(localeIdentifier: String = "en-AU") async throws {
        onEvent?(.status("检查 Apple 本机模型…"))
        let locale = Locale(identifier: localeIdentifier)
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            try await install(modules: [module], locale: supported)
            try Task.checkCancellation()
            try await prepare(modules: [module])
            resultsTask = Task { [weak self] in
                do { for try await result in module.results {
                    guard !Task.isCancelled else { break }
                    self?.emit(text: String(result.text.characters), range: result.range, final: result.isFinal)
                } } catch { if !Task.isCancelled { self?.onEvent?(.error(error.localizedDescription)) } }
            }
            onEvent?(.status("SpeechTranscriber · 本机英文"))
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = DictationTranscriber(locale: supported, contentHints: [.farField], transcriptionOptions: [], reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange])
            try await install(modules: [module], locale: supported)
            try Task.checkCancellation()
            try await prepare(modules: [module])
            resultsTask = Task { [weak self] in
                do { for try await result in module.results {
                    guard !Task.isCancelled else { break }
                    self?.emit(text: String(result.text.characters), range: result.range, final: result.isFinal)
                } } catch { if !Task.isCancelled { self?.onEvent?(.error(error.localizedDescription)) } }
            }
            onEvent?(.status("DictationTranscriber · 降级本机英文"))
        } else { throw WLFailure.message("此设备或语言没有可用英文转写模型；录音继续") }
    }
    private func install(modules: [any SpeechModule], locale: Locale) async throws {
        try Task.checkCancellation()
        let reserved = try await AssetInventory.reserve(locale: locale)
        guard reserved else { throw WLFailure.message("无法预留英文模型；请在系统设置检查语音模型") }
        let status = await AssetInventory.status(forModules: modules)
        onEvent?(.status("英文模型：\(String(describing: status))"))
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            onEvent?(.status("下载英文模型（录音继续）…"))
            try await request.downloadAndInstall()
        }
    }
    private func prepare(modules: [any SpeechModule]) async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { throw WLFailure.message("Apple Speech 没有可用音频格式") }
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(96))
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.start(inputSequence: stream)
        try Task.checkCancellation()
        self.analyzer = analyzer; bridge.attach(continuation, format: format)
    }
    private func emit(text: String, range: CMTimeRange, final: Bool) {
        let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
        guard start.isFinite, end.isFinite else { return }
        onEvent?(.result(SpeechPiece(text: text, start: start, end: end), final))
    }
    func finish() async {
        await bridge.finish()
        if let analyzer {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await analyzer.finalizeAndFinishThroughEndOfInput() }
                    group.addTask { try await Task.sleep(for: .seconds(8)); await analyzer.cancelAndFinishNow(); throw WLFailure.message("Speech finalization timeout; unfinished words retained in audio") }
                    _ = try await group.next(); group.cancelAll()
                }
            } catch { onEvent?(.error(error.localizedDescription)); await analyzer.cancelAndFinishNow() }
        }
        if let resultsTask { await resultsTask.value }
        self.resultsTask = nil; analyzer = nil
    }
}
