import AVFoundation
import WLCore

/// Closed-file replay has its own Speech instance/cursor. It cannot move live captions
/// backwards or reopen the recorder. Source offsets stay on the captured-audio axis.
@MainActor enum SpeechAudioRepair {
    static func repair(_ session: LectureSession, store: SessionStore) async throws {
        let ranges = try await store.audioRepairRanges(session.id)
        guard !ranges.isEmpty else { return }
        let offsets = try await store.audioOffsets(session.id)
        let files = session.audioFiles.sorted { (offsets[$0] ?? 0) < (offsets[$1] ?? 0) }
        for range in ranges {
            try Task.checkCancellation()
            let service = SpeechService(realtime: false)
            var buffer = SentenceBuffer(), pieces: [TranscriptSegment] = []
            var cursor = FinalSpeechCursor()
            var failure: String?
            service.onEvent = { event in
                switch event {
                case .result(let piece, true):
                    guard piece.start >= range.start - 0.02, piece.end <= range.end + 0.05, cursor.accept(piece) else { return }
                    if let s = buffer.append(piece) { pieces.append(s) }
                case .error(let error): failure = error
                case .dropped: failure = "补转写输入未完整提交"
                default: break
                }
            }
            do {
                try await service.start(localeIdentifier: UserDefaults.standard.string(forKey: "speechLocale") ?? "en-AU")
                var fed = false
                for name in files {
                    guard let fileStart = offsets[name] else { throw WLFailure.message("录音片段缺少时间信息") }
                    let file = try AVAudioFile(forReading: store.folder(session.id).appendingPathComponent(name))
                    let rate = file.processingFormat.sampleRate
                    let fileEnd = fileStart + Double(file.length) / rate
                    let start = max(range.start, fileStart), end = min(range.end, fileEnd)
                    guard end > start else { continue }
                    file.framePosition = AVAudioFramePosition(max(0, ((start - fileStart) * rate).rounded(.up)))
                    let until = min(file.length, AVAudioFramePosition(((end - fileStart) * rate).rounded(.down)))
                    while file.framePosition < until {
                        try Task.checkCancellation()
                        let position = file.framePosition
                        let capacity = AVAudioFrameCount(min(8192, until - position))
                        guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { throw WLFailure.message("补转写缓冲无法分配") }
                        try file.read(into: pcm, frameCount: capacity)
                        guard pcm.frameLength > 0 else { break }
                        let offset = fileStart + Double(position) / rate
                        try await service.feedForRepair(AudioPacket(buffer: pcm, offset: offset, capturedAt: session.startedAt.addingTimeInterval(offset)))
                        fed = true
                    }
                }
                await service.finish(); service.onEvent = nil
                try Task.checkCancellation()
                guard fed else { throw WLFailure.message("缺口对应录音不可读取") }
                if let tail = buffer.flush() { pieces.append(tail) }
                // Even a timed-out finalize can have valid results. Save those first.
                for var piece in pieces { piece.gptDeferred = true; _ = try await store.appendRepaired(piece, session: session.id) }
                if let failure { throw WLFailure.message(failure) }
                try await store.log(Diagnostic("speech_gap_repaired", offset: range.end,
                    fields: ["range_start": "\(range.start)", "range_end": "\(range.end)", "segments": "\(pieces.count)", "replay": "true"]), session: session.id)
            } catch {
                await service.finish(); service.onEvent = nil; throw error
            }
        }
    }
}
