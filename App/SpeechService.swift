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
    private var staged: [AudioPacket] = []
    private var stagedBytes = 0
    private var closed = false
    private var pendingGap: (Double, Double)?
    private let onDrop: @Sendable (Double, Double) -> Void
    private let onFailure: @Sendable (String) -> Void
    init(onDrop: @escaping @Sendable (Double, Double) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.onDrop = onDrop; self.onFailure = onFailure
    }
    func attach(_ continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        lock.lock()
        guard !closed else { lock.unlock(); continuation.finish(); return }
        self.continuation = continuation; target = format
        let prefix = staged; staged = []; stagedBytes = 0
        // Enqueue the prefix under the same lock used by offer: live input cannot pass it.
        queue.async { for packet in prefix { self.submit(packet, sink: continuation, format: format) } }
        lock.unlock()
    }
    func offer(_ packet: AudioPacket) {
        let duration = Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate
        lock.lock()
        guard !closed else { lock.unlock(); return }
        captureDates.observe(offset: packet.offset, capturedAt: packet.capturedAt)
        guard let sink = continuation, let format = target else {
            let bytes = Int(packet.buffer.frameLength) * Int(packet.buffer.format.streamDescription.pointee.mBytesPerFrame) * (packet.buffer.format.isInterleaved ? 1 : Int(packet.buffer.format.channelCount))
            if stagedBytes + bytes <= 8 * 1024 * 1024 && packet.offset + duration - (staged.first?.offset ?? packet.offset) <= 10 {
                staged.append(packet); stagedBytes += bytes; lock.unlock()
            } else { lock.unlock(); reportGap(packet.offset, packet.offset + duration) }
            return
        }
        guard slots.wait(timeout: .now()) == .success else { lock.unlock(); reportGap(packet.offset, packet.offset + duration); return }
        queue.async {
            defer { self.slots.signal() }
            self.submit(packet, sink: sink, format: format)
        }
        lock.unlock()
    }
    private func submit(_ packet: AudioPacket, sink: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        do {
            if converter?.outputFormat != format { converter = StreamingPCMConverter(outputFormat: format) }
            guard let output = try converter?.convert(packet.buffer, capturedAt: packet.offset) else { return }
            // bufferingOldest drops this offered input, so diagnostics name the actual gap.
            if case .dropped = sink.yield(AnalyzerInput(buffer: output.buffer, bufferStartTime: output.start)) {
                reportGap(output.start.seconds, output.start.seconds + Double(output.buffer.frameLength) / format.sampleRate)
            }
        } catch {
            converter?.resetAfterFailure()
            reportGap(packet.offset, packet.offset + Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate)
            onFailure("Speech PCM conversion: \(SpeechErrorDetails.describe(error))")
        }
    }
    private func reportGap(_ start: Double, _ end: Double) {
        lock.lock()
        if let gap = pendingGap, start <= gap.1 + 0.05 { pendingGap = (min(start, gap.0), max(end, gap.1)) }
        else {
            if let gap = pendingGap { onDrop(gap.0, gap.1) }
            pendingGap = (start, end)
        }
        if let gap = pendingGap, gap.1 - gap.0 >= 1 { pendingGap = nil; onDrop(gap.0, gap.1) }
        lock.unlock()
    }
    func captureDate(at offset: Double) -> Date? { lock.withLock { captureDates.date(at: offset) } }
    func offerForRepair(_ packet: AudioPacket) async throws {
        try Task.checkCancellation()
        let pair = lock.withLock { (continuation, target) }
        guard let sink = pair.0, let format = pair.1 else { throw WLFailure.message("补转写输入未准备") }
        let output: ConvertedPCM? = try await withCheckedThrowingContinuation { done in
            queue.async {
                do {
                    self.lock.withLock { self.captureDates.observe(offset: packet.offset, capturedAt: packet.capturedAt) }
                    if self.converter?.outputFormat != format { self.converter = StreamingPCMConverter(outputFormat: format) }
                    done.resume(returning: try self.converter?.convert(packet.buffer, capturedAt: packet.offset))
                } catch { done.resume(throwing: error) }
            }
        }
        guard let output else { return }
        let input = AnalyzerInput(buffer: output.buffer, bufferStartTime: output.start)
        while true {
            try Task.checkCancellation()
            switch sink.yield(input) {
            case .enqueued: return
            case .dropped: try await Task.sleep(for: .milliseconds(10))
            case .terminated: throw WLFailure.message("补转写输入已结束")
            @unknown default: throw WLFailure.message("补转写输入状态未知")
            }
        }
    }
    func finish() async {
        let sink = lock.withLock { () -> AsyncStream<AnalyzerInput>.Continuation? in
            closed = true
            if let gap = pendingGap { onDrop(gap.0, gap.1); pendingGap = nil }
            if let first = staged.first, let last = staged.last { onDrop(first.offset, last.offset + Double(last.buffer.frameLength) / last.buffer.format.sampleRate) }
            staged = []; stagedBytes = 0
            let sink = continuation; continuation = nil; target = nil; return sink
        }
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
    enum Event { case status(String), result(SpeechPiece, Bool), error(String), dropped(Double, Double), diagnostic(String, [String: String]) }
    var onEvent: ((Event) -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var warmedModule: SpeechTranscriber?
    private var warmedFormat: AVAudioFormat?
    private var warmedAnalyzer: SpeechAnalyzer?
    private var warmedLocale: String?
    private let mayInstall: Bool
    init(mayInstall: Bool = false) { self.mayInstall = mayInstall }
    static func prepareAssets(localeIdentifier: String) async throws {
        let service = SpeechService(mayInstall: true)
        let locale = Locale(identifier: localeIdentifier)
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            try await service.install(modules: [module], locale: supported)
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = DictationTranscriber(locale: supported, contentHints: [.farField], transcriptionOptions: [], reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange])
            try await service.install(modules: [module], locale: supported)
        } else { throw WLFailure.message("此设备或语言没有可用的英文模型") }
    }
    private lazy var bridge = SpeechInputBridge(onDrop: { [weak self] start, end in
        Task { @MainActor in self?.onEvent?(.dropped(start, end)) }
    }, onFailure: { [weak self] message in Task { @MainActor in self?.onEvent?(.error(message)) } })
    /// Safe nonblocking closure installed on the audio writer queue.
    func packetSink() -> @Sendable (AudioPacket) -> Void {
        let bridge = self.bridge
        return { bridge.offer($0) }
    }
    func feedForRepair(_ packet: AudioPacket) async throws { try await bridge.offerForRepair(packet) }
    func prewarm(localeIdentifier: String) {
        guard warmTask == nil else { return }
        warmTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard SpeechTranscriber.isAvailable,
                      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else { return }
                let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
                guard await AssetInventory.status(forModules: [module]) == .installed,
                      let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return }
                let analyzer = SpeechAnalyzer(modules: [module])
                try await analyzer.prepareToAnalyze(in: format); try Task.checkCancellation()
                warmedModule = module; warmedFormat = format; warmedAnalyzer = analyzer; warmedLocale = localeIdentifier
            } catch { /* Best-effort installed-model preparation; recording never waits here. */ }
        }
    }

    func start(localeIdentifier: String = "en-AU") async throws {
        await warmTask?.value; try Task.checkCancellation()
        if warmedLocale == localeIdentifier, let module = warmedModule, let format = warmedFormat, let prepared = warmedAnalyzer {
            warmedModule = nil; warmedAnalyzer = nil; warmedFormat = nil
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(384))
            try await prepared.start(inputSequence: stream)
            if Task.isCancelled { continuation.finish(); await prepared.cancelAndFinishNow(); throw CancellationError() }
            analyzer = prepared; bridge.attach(continuation, format: format)
            resultsTask = Task { [weak self] in
                do { for try await result in module.results {
                    if Task.isCancelled { break }
                    self?.emit(text: String(result.text.characters), range: result.range, final: result.isFinal)
                } } catch { if !Task.isCancelled { self?.onEvent?(.error(SpeechErrorDetails.describe(error))) } }
            }
            onEvent?(.status("SpeechTranscriber · 本机英文")); return
        }
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
            guard mayInstall else { throw WLFailure.message("英文模型未安装，请在设置中准备；原始录音继续保存") }
            onEvent?(.status("下载英文模型…"))
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
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(384))
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
        warmTask?.cancel(); warmedModule = nil; warmedAnalyzer = nil; warmedFormat = nil
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
