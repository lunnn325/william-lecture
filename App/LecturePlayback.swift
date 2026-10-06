import AVFoundation
import Combine
import WLCore

@MainActor final class LecturePlayback: ObservableObject {
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    private var timeline: PlaybackTimeline?
    private var folder: URL?
    private var player: AVAudioPlayer?
    private var delegate: LecturePlaybackDelegate?
    private var timer: Task<Void, Never>?
    private var index = 0
    private var generation = UUID()
    var recordingActive: () -> Bool = { false }
    var ready: Bool { timeline != nil && duration > 0 && !loading }
    func prepare(session: LectureSession, folder: URL, offsets: [String: Double]) async {
        stop(); timeline = nil; duration = 0; self.folder = nil
        let ticket = UUID(); generation = ticket; loading = true; error = ""
        defer { if generation == ticket { loading = false } }
        do {
            let slices = try await Task.detached(priority: .userInitiated) { () throws -> [PlaybackSlice] in
                var cursor = 0.0; var slices: [PlaybackSlice] = []
                for name in session.audioFiles {
                    try Task.checkCancellation()
                    guard name == URL(fileURLWithPath: name).lastPathComponent else { throw WLFailure.message("录音文件路径无效") }
                    let file = try AVAudioFile(forReading: folder.appendingPathComponent(name))
                    let seconds = Double(file.length) / file.processingFormat.sampleRate
                    guard seconds.isFinite, seconds > 0 else { throw WLFailure.message("录音片段没有可播放音频，原文件保留") }
                    let start = session.usesRecordingTimeline ? cursor : max(cursor, offsets[name] ?? cursor)
                    slices.append(PlaybackSlice(file: name, start: start, duration: seconds)); cursor = start + seconds
                }
                return slices
            }.value
            guard generation == ticket, !Task.isCancelled else { return }
            timeline = try PlaybackTimeline(slices: slices); self.folder = folder; duration = timeline?.duration ?? 0
        } catch { if generation == ticket { self.error = "回放不可用：\(error.localizedDescription)；文字稿和原始文件仍可查看" } }
    }
    func toggle() { if playing { pause() } else { play() } }
    func pause() { player?.pause(); playing = false; timer?.cancel(); timer = nil; updatePosition() }
    func play() {
        guard !recordingActive(), ready else { return }
        if position >= duration - 0.01 { position = 0; player = nil }
        if let player { playing = player.play(); startTimer() }
        else { seek(to: position, resume: true) }
    }
    func seek(to seconds: Double, resume: Bool = false) {
        guard !recordingActive(), let timeline, let location = timeline.position(at: seconds), let folder else { return }
        player?.stop(); timer?.cancel(); playing = false
        do {
            let next = try AVAudioPlayer(contentsOf: folder.appendingPathComponent(timeline.slices[location.index].file))
            let delegate = LecturePlaybackDelegate { [weak self] source, success in
                Task { @MainActor in
                    guard let self, self.player === source else { return }
                    if !success { self.error = "录音片段解码失败，原文件保留"; self.pause(); return }
                    if self.recordingActive() { self.stop(); return }
                    if location.index + 1 < timeline.slices.count {
                        self.seek(to: timeline.slices[location.index + 1].start, resume: true)
                    } else { self.position = self.duration; self.playing = false; self.timer?.cancel(); self.player = nil }
                }
            }
            self.delegate = delegate; next.delegate = delegate; next.currentTime = location.fileSeconds
            index = location.index; player = next; position = timeline.slices[index].start + location.fileSeconds
            if resume {
                // All routing changes are synchronous on MainActor and guarded against recording.
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                try AVAudioSession.sharedInstance().setActive(true)
                playing = next.play(); startTimer()
            }
        } catch { self.error = error.localizedDescription; player = nil; playing = false }
    }
    func stop() { generation = UUID(); player?.stop(); player = nil; playing = false; timer?.cancel(); timer = nil; position = 0 }
    private func updatePosition() {
        guard let timeline, let player, index < timeline.slices.count else { return }
        position = min(duration, timeline.slices[index].start + player.currentTime)
    }
    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if self.recordingActive() { self.stop(); return }
                self.updatePosition()
            }
        }
    }
}
private final class LecturePlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    let ended: (AVAudioPlayer, Bool) -> Void
    init(ended: @escaping (AVAudioPlayer, Bool) -> Void) { self.ended = ended }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { ended(player, flag) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { ended(player, false) }
}
