import AVFoundation
import Foundation

public struct PCMLevelSummary: Sendable {
    public let peak: Double
    public let rms: Double
    public let clippedFraction: Double
    public var peakDBFS: Double { 20 * log10(max(peak, 0.000001)) }
    public var rmsDBFS: Double { 20 * log10(max(rms, 0.000001)) }
}

/// Accumulate all channels across the whole diagnostic interval, not a single tap buffer.
public struct PCMLevelAccumulator {
    private var peak = 0.0
    private var squares = 0.0
    private var samples = 0
    private var clipped = 0
    public init() {}
    public mutating func append(_ buffer: AVAudioPCMBuffer) {
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        for channel in 0..<channels {
            for frame in 0..<frames {
                let lane = buffer.format.isInterleaved ? 0 : channel
                let index = buffer.format.isInterleaved ? frame * channels + channel : frame
                let value: Double
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32: guard let data = buffer.floatChannelData else { continue }; value = Double(data[lane][index])
                case .pcmFormatInt16: guard let data = buffer.int16ChannelData else { continue }; value = Double(data[lane][index]) / 32768
                case .pcmFormatInt32: guard let data = buffer.int32ChannelData else { continue }; value = Double(data[lane][index]) / 2147483648
                default: continue
                }
                guard value.isFinite else { continue }
                peak = max(peak, abs(value)); squares += value * value; samples += 1
                if abs(value) >= 0.999 { clipped += 1 }
            }
        }
    }
    public mutating func snapshotAndReset() -> PCMLevelSummary {
        let summary = PCMLevelSummary(peak: peak, rms: samples > 0 ? sqrt(squares / Double(samples)) : 0,
            clippedFraction: samples > 0 ? Double(clipped) / Double(samples) : 0)
        self = PCMLevelAccumulator(); return summary
    }
}

public enum PCMArchive {
    public static func open(at url: URL, inputFormat: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: inputFormat.commonFormat, interleaved: inputFormat.isInterleaved)
    }
}
