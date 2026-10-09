import AVFoundation
import Foundation
import Darwin
import WLCore
import WLAppleAudio

struct AudioPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let offset: Double
    let capturedAt: Date
}

/// Dedicated serial disk queue. Nothing on the microphone callback waits for Speech, GPT or UI.
final class AudioRecorder: @unchecked Sendable {
    enum Event: Sendable {
        case started(Double), chunk(String, Double), paused(Double), stopped(Double)
        case configuration([String: String]), metadataWarning(String)
        case interrupted(Double, Bool), recoveryRequested, routeChanged, failure(String, Double)
        case meter(Double, PCMLevelSummary, UInt64, Double, UInt64)
    }
    private let callbackLock = NSLock()
    private var eventCallback: (@Sendable (Event) -> Void)?
    private var packetCallback: (@Sendable (AudioPacket) -> Void)?
    var onEvent: (@Sendable (Event) -> Void)? {
        get { callbackLock.withLock { eventCallback } }
        set { callbackLock.withLock { eventCallback = newValue } }
    }
    var onPacket: (@Sendable (AudioPacket) -> Void)? {
        get { callbackLock.withLock { packetCallback } }
        set { callbackLock.withLock { packetCallback = newValue } }
    }
    private let queue = DispatchQueue(label: "WL.audio.disk", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 96)
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var inputFormat: AVAudioFormat?
    private var directory: URL?
    private var origin = Date()
    private var originUptime = 0.0
    private var recording = false
    private var tapInstalled = false
    private var chunkStart = 0.0
    private var nextIndex = 0
    private var lastMeter = 0.0
    private var capturedSeconds = 0.0
    private var levels = PCMLevelAccumulator()
    private var observers: [NSObjectProtocol] = []
    private var faultReported = false
    private let captureGate = CaptureGate()
    private var generation = 0
    private var closing = false
    private var pauseWaiters: [() -> Void] = []
    private var closedBytes: UInt64 = 0
    private var currentURL: URL?
    private var chunkHasFrames = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            if type == AVAudioSession.InterruptionType.began.rawValue {
                self.queue.async { if self.recording { self.pauseOnQueue { self.onEvent?(.interrupted(self.capturedSeconds, true)) } } }
            } else {
                let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) { self.onEvent?(.recoveryRequested) }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                let wasRecording = self.recording
                self.pauseOnQueue {
                    self.engine = AVAudioEngine()
                    if wasRecording { self.onEvent?(.interrupted(self.capturedSeconds, false)); self.onEvent?(.recoveryRequested) }
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            self.queue.async {
                if let changedEngine = note.object as? AVAudioEngine, changedEngine === self.engine,
                   self.recording && !self.engine.isRunning {
                    self.pauseOnQueue { self.onEvent?(.interrupted(self.capturedSeconds, false)); self.onEvent?(.recoveryRequested) }
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.onEvent?(.routeChanged)
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start(directory: URL, origin: Date) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw WLFailure.message("麦克风权限未开启") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { self.directory = directory; self.origin = origin; self.originUptime = ProcessInfo.processInfo.systemUptime - Date().timeIntervalSince(origin); try self.beginOnQueue(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func resume() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { do { try self.beginOnQueue(); continuation.resume() } catch { continuation.resume(throwing: error) } }
        }
    }
    func pause() async { await withCheckedContinuation { continuation in queue.async { self.pauseOnQueue { continuation.resume() } } } }
    func recordedDuration() async -> Double {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.capturedSeconds) } }
    }
    func stop() async {
        await withCheckedContinuation { continuation in queue.async {
            self.pauseOnQueue {
                self.onEvent?(.stopped(self.capturedSeconds))
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                continuation.resume()
            }
        } }
    }
    private func beginOnQueue() throws {
        guard !recording else { return }
        guard !closing else { throw WLFailure.message("录音正在保存尾部，请稍后恢复") }
        let session = AVAudioSession.sharedInstance()
        // Sample-buffer PiP requires a playback-capable category. Configure once before capture;
        // the PiP coordinator never changes the session while the microphone is running.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(48_000); try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw WLFailure.message("麦克风格式不可用") }
        onEvent?(.configuration(["category": session.category.rawValue, "mode": session.mode.rawValue,
            "input_route": session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", "),
            "sample_rate": "\(format.sampleRate)", "channels": "\(format.channelCount)",
            "input_gain": "\(session.inputGain)", "input_gain_settable": "\(session.isInputGainSettable)",
            "pcm_format": format.description]))
        let offset = capturedSeconds
        try openChunk(format: format, offset: offset)
        faultReported = false; recording = true
        generation = captureGate.open()
        let captureGeneration = generation
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, time in
            guard let self else { return }
            // Copy tap-owned memory before returning. A full disk queue is a recording fault, never a silent drop.
            guard self.slots.wait(timeout: .now()) == .success else {
                self.reportCaptureFailure("Audio disk queue overflow; capture stopped", generation: captureGeneration)
                return
            }
            guard let copy = Self.clone(buffer) else { self.slots.signal(); self.reportCaptureFailure("Cannot copy audio buffer", generation: captureGeneration); return }
            let start = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) - self.originUptime : Date().timeIntervalSince(self.origin) - Double(copy.frameLength) / copy.format.sampleRate
            let capturedAt = self.origin.addingTimeInterval(max(0, start))
            let accepted = self.captureGate.offer(generation: captureGeneration) { self.queue.async {
                defer { self.slots.signal() }
                guard self.generation == captureGeneration, self.file != nil else { return }
                // Assign positions on the same serial queue that successfully writes PCM.
                // Host time is retained only for real latency; pauses never advance this axis.
                let packet = AudioPacket(buffer: copy, offset: self.capturedSeconds, capturedAt: capturedAt)
                do {
                    if packet.offset - self.chunkStart >= 30 || self.inputFormat != copy.format { self.closeChunk(); try self.openChunk(format: copy.format, offset: packet.offset) }
                    if !self.chunkHasFrames {
                        self.chunkHasFrames = true; self.chunkStart = packet.offset
                        self.writeIndex(Diagnostic("audio_chunk_first_frame", offset: packet.offset, fields: ["file": self.currentURL!.lastPathComponent]))
                    }
                    try self.file?.write(from: copy)
                    self.capturedSeconds += Double(copy.frameLength) / copy.format.sampleRate
                    self.levels.append(copy)
                    // Nonblocking offer only; Speech copies/converts on its own queue.
                    self.onPacket?(packet)
                    if packet.offset - self.lastMeter >= 1 {
                        self.lastMeter = packet.offset
                        let currentBytes = self.currentURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }?.uint64Value ?? 0
                        self.onEvent?(.meter(self.capturedSeconds, self.levels.snapshotAndReset(), Self.memoryBytes(), self.capturedSeconds, self.closedBytes + currentBytes))
                    }
                } catch { self.fail("Audio write: \(error.localizedDescription)", offset: packet.offset) }
            } }
            if !accepted { self.slots.signal() }
        }
        tapInstalled = true
        do { engine.prepare(); try engine.start(); onEvent?(.started(offset)) }
        catch { pauseOnQueue {}; throw error }
    }
    private func openChunk(format: AVAudioFormat, offset: Double) throws {
        guard let directory else { throw WLFailure.message("Missing audio directory") }
        let name = String(format: "audio-%05d.caf", nextIndex); nextIndex += 1
        let url = directory.appendingPathComponent(name)
        // Recoverable chunks; 16-bit PCM reduces space, preserving microphone sample rate/channels.
        file = try PCMArchive.open(at: url, inputFormat: format)
        currentURL = url
        chunkHasFrames = false
        inputFormat = format
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var resourceURL = url
        var resourceValues = URLResourceValues(); resourceValues.isExcludedFromBackup = true
        try resourceURL.setResourceValues(resourceValues)
        chunkStart = offset
        writeIndex(Diagnostic("audio_chunk_open", offset: offset, fields: ["file": name, "sample_rate": "\(format.sampleRate)", "channels": "\(format.channelCount)"]))
        onEvent?(.chunk(name, offset))
    }
    private func closeChunk() {
        file = nil
        if let currentURL {
            if chunkHasFrames {
                writeIndex(Diagnostic("audio_chunk_close", offset: capturedSeconds, fields: ["file": currentURL.lastPathComponent]))
            }
            closedBytes += ((try? FileManager.default.attributesOfItem(atPath: currentURL.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        }
        currentURL = nil
    }
    private func writeIndex(_ item: Diagnostic) {
        guard let directory else { return }
        var item = item
        item.fields["timeline"] = SessionTimeline.recordedAudio.rawValue
        item.fields["captured_seconds"] = "\(capturedSeconds)"
        item.fields["wall_offset"] = "\(item.at.timeIntervalSince(origin))"
        do { try JSONLines.append(item, to: directory.appendingPathComponent("audio-index.jsonl")) }
        catch { onEvent?(.metadataWarning("音频索引写盘失败：\(error.localizedDescription)；原始音频继续录制")) }
    }
    private func pauseOnQueue(_ completion: @escaping () -> Void) {
        pauseWaiters.append(completion)
        guard !closing else { return }
        closing = true
        captureGate.close()
        recording = false
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        // Admission is closed, so this barrier follows every accepted audio write,
        // including callbacks which enqueued while the pause operation was starting.
        queue.async {
            self.closeChunk(); self.closing = false
            self.onEvent?(.paused(self.capturedSeconds))
            let waiters = self.pauseWaiters; self.pauseWaiters.removeAll()
            waiters.forEach { $0() }
        }
    }
    private func fail(_ message: String, offset: Double) {
        guard !faultReported else { return }; faultReported = true
        pauseOnQueue { self.onEvent?(.failure(message, offset)) }
    }
    private func reportCaptureFailure(_ message: String, generation: Int) {
        captureGate.offer(generation: generation) { queue.async {
            guard self.generation == generation, self.recording else { return }
            self.fail(message, offset: self.capturedSeconds)
        } }
    }
    private static func clone(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<src.count {
            guard let from = src[index].mData, let to = dst[index].mData else { return nil }
            memcpy(to, from, Int(src[index].mDataByteSize))
        }
        return copy
    }
    private static func memoryBytes() -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
