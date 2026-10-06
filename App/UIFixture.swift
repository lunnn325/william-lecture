import SwiftUI
import AVFoundation
import WLCore

// Release builds contain no simulated lecture or alternate storage root.
struct UIFixtureAppearance: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--wl-large-type") {
            content.dynamicTypeSize(.accessibility2)
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--wl-dark") ? .dark : .light)
        } else if ProcessInfo.processInfo.arguments.contains("--wl-ui-fixture") {
            content.preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--wl-dark") ? .dark : .light)
        } else { content }
        #else
        content
        #endif
    }
}

#if DEBUG
extension LectureController {
    var isUIFixture: Bool { ProcessInfo.processInfo.arguments.contains("--wl-ui-fixture") }
    func installUIFixture() async throws {
        mode = .mock; course = "ECON1111 · 微观经济学"
        localStatus = "模拟器演示，不调用 Apple 语言模型"; translationStatus = "演示翻译"
        var lesson = LectureSession(course: course, now: Date(timeIntervalSince1970: 1791244800))
        lesson.id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        lesson.state = ProcessInfo.processInfo.arguments.contains("--wl-fixture-active") ? .recording : .stopped
        lesson.stoppedAt = lesson.state == .stopped ? lesson.startedAt.addingTimeInterval(24) : nil
        try await populateFixture(&lesson)
        if lesson.state == .recording { session = lesson; visible = try await store.segments(lesson.id); sessionNotes = try await store.notes(lesson.id); audioStatus = "演示录音" }
    }
    func startUIFixture() async {
        do {
            var lesson = LectureSession(course: course)
            try await populateFixture(&lesson)
            session = lesson; visible = try await store.segments(lesson.id)
            latestCaptionUpdate = visible.last; sessionNotes = []; currentChinese = ""; volatileEnglish = ""; warning = ""
            audioStatus = "演示录音"; speechStatus = "演示英文，不调用麦克风"
            await refreshHistory()
        } catch { warning = error.localizedDescription }
    }
    private func populateFixture(_ lesson: inout LectureSession) async throws {
        lesson.updateRecordingDuration(24); lesson.audioFiles = ["fixture.caf"]
        try await store.save(lesson)
        let folder = store.folder(lesson.id), audio = folder.appendingPathComponent("fixture.caf")
        if !FileManager.default.fileExists(atPath: audio.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 24)!
            buffer.frameLength = buffer.frameCapacity
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 220 / 48000) * 0.05) }
            let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer)
        }
        let examples = [
            ("An externality affects people outside the transaction.", "外部性会影响交易双方之外的人。"),
            ("The social cost includes the cost borne by others.", "社会成本也包括其他人承担的成本。"),
            ("A tax can bring private incentives closer to social costs.", "税收可以使私人激励更接近社会成本。"),
            ("The marginal benefit is not the same as the total benefit.", "边际收益和总收益并不相同。"),
            ("We should compare the next unit of benefit with its cost.", "我们应比较下一单位的收益与成本。"),
            ("A price ceiling below equilibrium creates a shortage.", "低于均衡价格的价格上限会造成短缺。")
        ]
        for index in 0..<18 {
            let example = examples[index % examples.count]
            var segment = TranscriptSegment(start: Double(index) * 1.3, end: Double(index + 1) * 1.3, english: example.0)
            segment.id = UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index + 1))!
            segment.chinese = example.1; segment.status = .mock
            try await store.append(segment, session: lesson.id)
        }
        try await store.log(Diagnostic("ui_fixture", fields: ["mock": "true", "purpose": "simulator flow and screenshots only"]), session: lesson.id)
    }
}
#endif
