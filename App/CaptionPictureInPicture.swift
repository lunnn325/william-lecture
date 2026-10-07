import SwiftUI
import AVKit
import CoreMedia
import WLCore

/// Live captions rendered into real video frames for the system PiP window.
/// This never configures AVAudioSession or owns/cancels the microphone pipeline.
@MainActor final class CaptionPictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var status = "已关闭"
    @Published private(set) var isActive = false
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    var onSetPlaying: ((Bool) -> Void)?
    var onDiagnostic: ((String, [String: String]) -> Void)?
    private var controller: AVPictureInPictureController?
    private weak var surface: CaptionVideoSurface?
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

    func attach(_ view: CaptionVideoSurface) {
        let changedSurface = surface !== view
        surface = view
        if changedSurface { lastFrameAt = .distantPast }
        if changedSurface, let controller {
            controller.contentSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
        }
        if view.displayLayer.controlTimebase == nil {
            var timebase: CMTimebase?
            if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr,
               let timebase {
                CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
                CMTimebaseSetRate(timebase, rate: 1); view.displayLayer.controlTimebase = timebase
            }
        }
        prepareController(); render()
    }
    func update(enabled: Bool, session: UUID?, active: Bool, recording: Bool, course: String, english: String, chinese: String?, elapsed: Double) {
        let changedClassroom = classroom != session
        self.enabled = enabled; classroom = session; hasLecture = active; playing = recording
        self.course = course; self.english = english; self.chinese = chinese; self.elapsed = elapsed
        if changedClassroom { stop(); surface?.displayLayer.flushAndRemoveImage(); lastFrameAt = .distantPast }
        guard enabled, active, supported else {
            stop(); timer?.cancel(); timer = nil
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
            status = !enabled ? "已关闭" : supported ? "录课时可用" : "此设备暂不支持字幕小窗"
            return
        }
        prepareController(); controller?.canStartPictureInPictureAutomaticallyFromInline = true
        controller?.invalidatePlaybackState(); render()
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, enabled, hasLecture else { return }
                    render()
                }
            }
        }
    }
    private func prepareController() {
        guard controller == nil, enabled, hasLecture, supported, let surface else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: surface.displayLayer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self; pip.requiresLinearPlayback = true
        pip.canStartPictureInPictureAutomaticallyFromInline = true; controller = pip
        status = "切换 App 时显示最新字幕"
    }
    func start() {
        guard enabled, hasLecture, let controller else { return }
        render(); controller.invalidatePlaybackState()
        guard controller.isPictureInPicturePossible else { status = "小窗暂不可用，请稍后重试"; return }
        if !controller.isPictureInPictureActive { controller.startPictureInPicture() }
    }
    func stop() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }
    private func render() {
        guard enabled, hasLecture, let layer = surface?.displayLayer else { return }
        guard Date().timeIntervalSince(lastFrameAt) >= 0.5 else { return }
        lastFrameAt = Date()
        autoreleasepool {
            let width = 960, height = 540
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
                  let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context); defer { UIGraphicsPopContext() }
            UIColor(red: 0.10, green: 0.15, blue: 0.22, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            draw(course, rect: CGRect(x: 36, y: 22, width: 670, height: 44), size: 27, color: .white)
            draw(SessionStore.readingTime(elapsed), rect: CGRect(x: 740, y: 22, width: 190, height: 44), size: 27, color: .lightGray)
            draw(english.isEmpty ? "暂无字幕" : english, rect: CGRect(x: 36, y: 85, width: 888, height: 132), size: 36, color: UIColor(white: 0.76, alpha: 1))
            draw(chinese ?? "…", rect: CGRect(x: 36, y: 239, width: 888, height: 224), size: 49, color: .white)
            draw(playing ? "录音中" : "已暂停", rect: CGRect(x: 36, y: 485, width: 888, height: 38), size: 26, color: .lightGray)
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
                  let format else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
                attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            if layer.status == .failed { layer.flush() }
            if layer.isReadyForMoreMediaData { layer.enqueue(sample) }
        }
    }
    private func draw(_ text: String, rect: CGRect, size: CGFloat, color: UIColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 7; paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph], context: nil)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard enabled, hasLecture, isActive, playing != self.playing else { return }; onSetPlaying?(playing)
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        hasLecture ? CMTimeRange(start: .zero, duration: .positiveInfinity) : .invalid
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { !playing }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) { render() }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) { completion() }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true; status = "小窗已打开"; onDiagnostic?("caption_pip_start", [:])
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false; status = enabled ? "小窗已关闭；录音状态不变" : "已关闭"; onDiagnostic?("caption_pip_stop", [:])
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isActive = false; status = "小窗暂不可用，请稍后重试"
        onDiagnostic?("caption_pip_error", ["error": error.localizedDescription])
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

final class CaptionVideoSurface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) { super.init(frame: frame); displayLayer.videoGravity = .resizeAspect }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
struct CaptionPictureInPicturePreview: UIViewRepresentable {
    let coordinator: CaptionPictureInPicture
    func makeUIView(context: Context) -> CaptionVideoSurface {
        let view = CaptionVideoSurface(); coordinator.attach(view); return view
    }
    func updateUIView(_ uiView: CaptionVideoSurface, context: Context) { coordinator.attach(uiView) }
}
