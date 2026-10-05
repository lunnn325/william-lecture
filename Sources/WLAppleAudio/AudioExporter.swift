import AVFoundation
import Foundation

public struct AudioExportChunk: Sendable {
    public let url: URL
    public let start: Double?
    public init(url: URL, start: Double?) { self.url = url; self.start = start }
}

/// Streams CAF into AAC M4A with bounded PCM memory. Known recording gaps become silence,
/// preserving the session time axis. A bad chunk fails the export; originals remain untouched.
public enum AudioExporter {
    public static func m4a(chunks: [AudioExportChunk], destination: URL) async throws -> URL {
        let task = Task.detached(priority: .utility) { try encode(chunks: chunks, destination: destination) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func encode(chunks: [AudioExportChunk], destination: URL) throws -> URL {
        guard !chunks.isEmpty else { throw ConversionFailure("没有可导出的音频片段") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ConversionFailure("导出文件已存在") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("partial-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw ConversionFailure("无法创建导出音频格式") }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                      AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
        var writer: AVAudioFile? = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var writtenFrames: Int64 = 0
        for chunk in chunks {
            try Task.checkCancellation()
            let reader = try AVAudioFile(forReading: chunk.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard reader.length > 0, reader.processingFormat.sampleRate > 0 else { throw ConversionFailure("音频片段为空或损坏：\(chunk.url.lastPathComponent)") }
            if let start = chunk.start {
                guard start.isFinite, start >= 0, start < 24 * 3600 else { throw ConversionFailure("音频时间轴不合法") }
                let gap = Int64((start * 48_000).rounded()) - writtenFrames
                guard gap >= -2400 else { throw ConversionFailure("音频片段时间范围重叠，无法可靠合并") }
                var remaining = max(0, gap)
                while remaining > 0 {
                    try Task.checkCancellation()
                    silence.frameLength = AVAudioFrameCount(min(4096, remaining))
                    memset(silence.floatChannelData![0], 0, Int(silence.frameLength) * MemoryLayout<Float>.size)
                    try writer?.write(from: silence)
                    remaining -= Int64(silence.frameLength); writtenFrames += Int64(silence.frameLength)
                }
            }
            guard let input = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096) else { throw ConversionFailure("无法读取音频片段") }
            let converter = StreamingPCMConverter(outputFormat: format)
            while reader.framePosition < reader.length {
                try Task.checkCancellation()
                let offset = Double(reader.framePosition) / reader.processingFormat.sampleRate
                try reader.read(into: input)
                guard input.frameLength > 0 else { throw ConversionFailure("音频片段提前结束：\(chunk.url.lastPathComponent)") }
                if let output = try converter.convert(input, capturedAt: offset) {
                    try writer?.write(from: output.buffer); writtenFrames += Int64(output.buffer.frameLength)
                }
            }
            for output in try converter.finish() {
                try writer?.write(from: output.buffer); writtenFrames += Int64(output.buffer.frameLength)
            }
        }
        writer = nil // Finalize AAC headers before publishing the file.
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
