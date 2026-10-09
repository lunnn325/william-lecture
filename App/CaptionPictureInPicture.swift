import SwiftUI
import AVKit
import CoreMedia
import WLCore

/// AVKit's synchronous playback queries can arrive off the main thread.
private final class CaptionPlaybackState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var playing = false
    func set(active: Bool, playing: Bool) { lock.lock(); defer { lock.unlock() }; self.active = active; self.playing = playing }
    func snapshot() -> (active: Bool, playing: Bool) { lock.lock(); defer { lock.unlock() }; return (active, playing) }
}

/// Live captions rendered into real video frames for the system PiP window.
/// This never configures AVAudioSession or owns/cancels the microphone pipeline.
@MainActor final class CaptionPictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var status = "已关闭"
    @Published private(set) var isActive = false
    @Published private(set) var isReady = false
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    var onDiagnostic: ((String, [String: String]) -> Void)?
    private var controller: AVPictureInPictureController?
    // One source for the entire coordinator lifetime, including SwiftUI view rebuilds.
    let previewSurface = CaptionVideoSurface()
    private var presentation = CaptionWindowPlayback()
    private var programmaticStop = false
    private var renderStatus: Int?
    private var lastRenderError = ""
    private(set) var frameProbe = ""
    private var timer: Task<Void, Never>?
    private var classroom: UUID?
    private var enabled = false
    private var hasLecture = false
    private var playing = false
    private var course = ""
    private var english = ""
    private var chinese: String?
    private var elapsed = 0.0
    private var lastFrameAt = Date.distantPast
    private var readiness: NSKeyValueObservation?
    private var needsFirstFrame = true
    private var startRequested = false
    private var startInFlight = false
    private var startDeadline = Date.distantPast
    private var foreground = true
    private var manualStart = false
    private nonisolated let playbackState = CaptionPlaybackState()

    func attach(_ view: CaptionVideoSurface) {
        guard view === previewSurface else { return }
        if view.displayLayer.controlTimebase == nil {
            var timebase: CMTimebase?
            if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr,
               let timebase {
                CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
                CMTimebaseSetRate(timebase, rate: 1); view.displayLayer.controlTimebase = timebase
            }
        }
        prepareController(); render(); refreshReadiness()
    }
    func update(enabled: Bool, session: UUID?, active: Bool, recording: Bool, course: String, english: String, chinese: String?, elapsed: Double) {
        let changedClassroom = classroom != session
        if enabled && !self.enabled { presentation.openManually() }
        self.enabled = enabled; classroom = session; hasLecture = active; playing = recording
        playbackState.set(active: enabled && active, playing: !presentation.paused)
        self.course = course; self.english = english; self.chinese = chinese; self.elapsed = elapsed
        if changedClassroom {
            stop(); presentation.reset(); previewSurface.displayLayer.flushAndRemoveImage()
            lastFrameAt = .distantPast; needsFirstFrame = true; renderStatus = nil
            playbackState.set(active: enabled && active, playing: true)
        }
        guard enabled, active, supported else {
            stop(); timer?.cancel(); timer = nil
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
            status = !enabled ? "已关闭" : supported ? "录课时可用" : "此设备暂不支持字幕小窗"
            return
        }
        prepareController(); controller?.canStartPictureInPictureAutomaticallyFromInline = presentation.automaticStartAllowed
        controller?.invalidatePlaybackState(); render()
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, enabled, hasLecture else { return }
                    render(); tryPendingStart()
                }
            }
        }
    }
    private func prepareController() {
        guard controller == nil, enabled, hasLecture, supported else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: previewSurface.displayLayer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self; pip.requiresLinearPlayback = true
        pip.canStartPictureInPictureAutomaticallyFromInline = true; controller = pip
        readiness = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshReadiness() }
        }
        refreshReadiness()
    }
    func start() {
        guard enabled, hasLecture, supported else { return }
        presentation.openManually(); playbackState.set(active: true, playing: true)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        manualStart = true; render(force: true); requestStart()
    }
    func sceneChanged(_ phase: ScenePhase) {
        if phase == .active {
            foreground = true; stop()
        } else {
            foreground = false
            // Inactive includes a cancelled Home gesture: prepare, but never clear captions.
            render(force: true)
            if phase == .background && enabled && hasLecture && presentation.automaticStartAllowed { manualStart = false; requestStart() }
        }
    }
    private func requestStart() {
        startRequested = true; startDeadline = Date().addingTimeInterval(8)
        prepareController(); render(); controller?.invalidatePlaybackState(); tryPendingStart()
    }
    private func refreshReadiness() {
        guard enabled, hasLecture else { isReady = false; return }
        let possible = controller?.isPictureInPicturePossible == true
        if possible != isReady {
            isReady = possible
            onDiagnostic?("caption_pip_readiness", ["possible": String(possible)])
        }
        if !isActive && !startInFlight { status = possible ? "切换 App 时显示字幕" : "小窗正在准备" }
        tryPendingStart()
    }
    private func tryPendingStart() {
        guard startRequested, !startInFlight, enabled, hasLecture, !foreground || manualStart else { return }
        if Date() > startDeadline {
            startRequested = false; status = "小窗暂不可用，请重试"
            onDiagnostic?("caption_pip_start_timeout", [:]); return
        }
        guard let controller, controller.isPictureInPicturePossible, previewSurface.window != nil,
              !needsFirstFrame, previewSurface.displayLayer.status != .failed else { return }
        if controller.isPictureInPictureActive { startRequested = false; return }
        startInFlight = true; controller.startPictureInPicture()
    }
    func stop() {
        startRequested = false; manualStart = false
        if controller?.isPictureInPictureActive == true || startInFlight {
            programmaticStop = true; controller?.stopPictureInPicture()
        }
    }
    private func render(force: Bool = false) {
        guard enabled, hasLecture, !presentation.paused || force || needsFirstFrame else { return }
        let layer = previewSurface.displayLayer
        guard force || Date().timeIntervalSince(lastFrameAt) >= 0.5 else { return }
        lastFrameAt = Date()
        autoreleasepool {
            let width = 960, height = 540
            var buffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
            let allocation = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
            guard allocation == kCVReturnSuccess, let buffer else { frameError("allocate", code: allocation); return }
            let lock = CVPixelBufferLockBaseAddress(buffer, [])
            guard lock == kCVReturnSuccess else { frameError("lock", code: lock); return }
            var locked = true
            defer { if locked { CVPixelBufferUnlockBaseAddress(buffer, []) } }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { frameError("context"); return }
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            UIColor(red: 0.10, green: 0.15, blue: 0.22, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            draw(course, rect: CGRect(x: 36, y: 22, width: 670, height: 44), size: 27, color: .white)
            draw(SessionStore.readingTime(elapsed), rect: CGRect(x: 740, y: 22, width: 190, height: 44), size: 27, color: .lightGray)
            draw(english.isEmpty ? "暂无字幕" : english, rect: CGRect(x: 36, y: 85, width: 888, height: 132), size: 36, color: UIColor(white: 0.76, alpha: 1))
            draw(chinese ?? "…", rect: CGRect(x: 36, y: 239, width: 888, height: 224), size: 49, color: .white)
            draw(presentation.caption(recording: playing), rect: CGRect(x: 36, y: 485, width: 888, height: 38), size: 26, color: .lightGray)
            context.flush(); UIGraphicsPopContext()
            // CPU drawing must be complete and unlocked before the compositor reads.
            if needsFirstFrame, let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
                var bright = 0
                for y in Swift.stride(from: 0, to: height, by: 8) {
                    for x in Swift.stride(from: 0, to: width, by: 8) {
                        let i = y * stride + x * 4
                        if bytes[i] > 160 && bytes[i + 1] > 160 && bytes[i + 2] > 160 { bright += 1 }
                    }
                }
                frameProbe = "iosurface=\(CVPixelBufferGetIOSurface(buffer) != nil); opaque=\(bytes[3] == 255); text_pixels=\(bright)"
            }
            CVPixelBufferUnlockBaseAddress(buffer, []); locked = false
            var format: CMVideoFormatDescription?
            let formatResult = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
            guard formatResult == noErr, let format else { frameError("format", code: formatResult); return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 2), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            let sampleResult = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample)
            guard sampleResult == noErr, let sample else { frameError("sample", code: sampleResult); return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
                dictionary[kCMSampleAttachmentKey_DisplayImmediately as String] = true
            }
            if layer.status == .failed {
                onDiagnostic?("caption_pip_render_error", ["error": layer.error?.localizedDescription ?? "未知错误"])
                layer.flush(); needsFirstFrame = true
            }
            // Initial readiness can depend on receiving the first real frame.
            if needsFirstFrame || layer.isReadyForMoreMediaData {
                let first = needsFirstFrame
                layer.enqueue(sample); needsFirstFrame = false; lastRenderError = ""
                if first { onDiagnostic?("caption_pip_first_frame", ["iosurface": "\(CVPixelBufferGetIOSurface(buffer) != nil)",
                    "width": "\(width)", "height": "\(height)", "duration_ms": "500", "pixels": frameProbe]) }
            }
            if renderStatus != layer.status.rawValue {
                renderStatus = layer.status.rawValue
                onDiagnostic?("caption_pip_render_status", ["status": "\(layer.status.rawValue)", "ready": "\(layer.isReadyForMoreMediaData)"])
            }
        }
    }
    private func frameError(_ stage: String, code: Int32 = -1) {
        let key = "\(stage):\(code)"
        guard lastRenderError != key else { return }
        lastRenderError = key; status = "字幕小窗暂不可用，可重试"
        onDiagnostic?("caption_pip_frame_error", ["stage": stage, "code": "\(code)"])
    }
    #if DEBUG
    func probeFrameForTesting() -> String {
        enabled = true; hasLecture = true; course = "[MOCK] ECON1111"
        english = "The marginal cost is five."; chinese = "边际成本是五。"
        needsFirstFrame = true; render(force: true)
        return frameProbe.isEmpty ? "frame_failed" : frameProbe
    }
    #endif
    private func draw(_ text: String, rect: CGRect, size: CGFloat, color: UIColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 7; paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph], context: nil)
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor [weak self] in
            guard let self, enabled, hasLecture, isActive else { return }
            presentation.setPlaying(playing)
            playbackState.set(active: true, playing: playing)
            render(force: true); controller?.invalidatePlaybackState()
            onDiagnostic?("caption_pip_display_playback", ["playing": "\(playing)", "recording": "\(self.playing)"])
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        playbackState.snapshot().active ? CMTimeRange(start: .zero, duration: .positiveInfinity) : .invalid
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { !playbackState.snapshot().playing }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        Task { @MainActor [weak self] in self?.render() }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) { completion() }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            startInFlight = false; startRequested = false
            guard enabled, hasLecture, !foreground || manualStart else { controller?.stopPictureInPicture(); return }
            isActive = true; status = "小窗已打开"; onDiagnostic?("caption_pip_start", [:])
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isActive = false; startInFlight = false; startRequested = false
            presentation.close(userInitiated: !programmaticStop); programmaticStop = false
            playbackState.set(active: enabled && hasLecture, playing: true)
            controller?.canStartPictureInPictureAutomaticallyFromInline = presentation.automaticStartAllowed && enabled && hasLecture
            status = enabled ? "小窗已关闭；录音状态不变" : "已关闭"; onDiagnostic?("caption_pip_stop", [:])
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, enabled else { return }
            isActive = false; startInFlight = false; startRequested = false
            status = "小窗暂不可用，请稍后重试"; onDiagnostic?("caption_pip_error", ["error": message])
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor [weak self] in self?.programmaticStop = true; completionHandler(true) }
    }
}

final class CaptionVideoSurface: UIView {
    var onReady: (() -> Void)?
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) { super.init(frame: frame); displayLayer.videoGravity = .resizeAspect }
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { onReady?() } }
    override func layoutSubviews() { super.layoutSubviews(); if window != nil && bounds.width > 0 && bounds.height > 0 { onReady?() } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
struct CaptionPictureInPicturePreview: UIViewRepresentable {
    let coordinator: CaptionPictureInPicture
    func makeUIView(context: Context) -> CaptionVideoSurface {
        let view = coordinator.previewSurface; view.isAccessibilityElement = false; view.accessibilityElementsHidden = true
        view.onReady = { [weak coordinator, weak view] in if let view { coordinator?.attach(view) } }
        coordinator.attach(view); return view
    }
    func updateUIView(_ uiView: CaptionVideoSurface, context: Context) { coordinator.attach(uiView) }
}
