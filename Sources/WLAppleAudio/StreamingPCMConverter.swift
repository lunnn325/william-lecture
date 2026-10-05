import AVFoundation
import CoreMedia
import Foundation

public struct ConvertedPCM {
    public let buffer: AVAudioPCMBuffer
    public let start: CMTime
    public var end: CMTime {
        CMTimeAdd(start, CMTime(value: Int64(buffer.frameLength), timescale: CMTimeScale(buffer.format.sampleRate)))
    }
}

/// Confine to one serial queue. Timestamps follow actual output frames rather than
/// applying every input timestamp to resampled data (which may retain priming frames).
public final class StreamingPCMConverter {
    public let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var expectedInputEnd: Double?
    private var nextOutputTime: CMTime?
    private var segmentStart = 0.0
    public init(outputFormat: AVAudioFormat) { self.outputFormat = outputFormat }

    public func convert(_ input: AVAudioPCMBuffer, capturedAt offset: Double) throws -> ConvertedPCM? {
        guard input.frameLength > 0, offset.isFinite else { return nil }
        let gap = expectedInputEnd.map { offset - $0 } ?? 0
        if inputFormat != input.format || gap > 0.005 {
            // Real capture gaps begin a new resampling segment, never carrying old audio across it.
            inputFormat = input.format
            segmentStart = max(offset, nextOutputTime?.seconds ?? offset)
            nextOutputTime = CMTime(seconds: segmentStart, preferredTimescale: 1_000_000_000)
            if input.format != outputFormat {
                converter = AVAudioConverter(from: input.format, to: outputFormat)
                guard converter != nil else { throw ConversionFailure("Cannot create PCM converter") }
            } else { converter = nil }
        }
        expectedInputEnd = offset + Double(input.frameLength) / input.format.sampleRate
        if input.format == outputFormat { return timestamp(input) }
        guard let converter else { throw ConversionFailure("PCM converter unavailable") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw ConversionFailure("Cannot allocate PCM output") }
        var supplied = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error else { throw ConversionFailure("PCM conversion failed") }
        return output.frameLength > 0 ? timestamp(output) : nil
    }

    /// Drain the resampler tail before finalizing Speech, retaining the last spoken samples.
    public func finish() throws -> [ConvertedPCM] {
        guard let converter else { return [] }
        var tail: [ConvertedPCM] = []
        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2048) else { throw ConversionFailure("Cannot allocate converter tail") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            if let error { throw error }
            guard status != .error else { throw ConversionFailure("PCM tail conversion failed") }
            if output.frameLength > 0 { tail.append(timestamp(output)) }
            if status == .endOfStream || output.frameLength == 0 { self.converter = nil; return tail }
        }
        throw ConversionFailure("PCM converter tail exceeded drain limit")
    }
    public func resetAfterFailure() {
        converter = nil; inputFormat = nil; expectedInputEnd = nil
        // Retain the last successful output end so restarting cannot overlap input already sent.
    }
    private func timestamp(_ buffer: AVAudioPCMBuffer) -> ConvertedPCM {
        let result = ConvertedPCM(buffer: buffer, start: nextOutputTime ?? CMTime(seconds: segmentStart, preferredTimescale: 1_000_000_000))
        nextOutputTime = result.end
        return result
    }
}

public struct ConversionFailure: Error, LocalizedError {
    let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
