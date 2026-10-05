import AVFoundation
import CoreMedia
import XCTest
@testable import WLAppleAudio

final class AudioTests: XCTestCase {
    func test48kTo16kPreservesAudioFramesLevelsAndContiguousTimes() throws {
        try verifyResampling(inputRate: 48_000, inputChannels: 1, chunkSize: 2048)
    }
    func test44100To16kOddChunksRemainContiguous() throws {
        try verifyResampling(inputRate: 44_100, inputChannels: 1, chunkSize: 511)
    }
    func testStereoToMonoResamplingRemainsContiguous() throws {
        try verifyResampling(inputRate: 48_000, inputChannels: 2, chunkSize: 2048)
    }
    func testSourceGapIsPreservedAndFailureResetCannotMoveTimeBackwards() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = StreamingPCMConverter(outputFormat: format)
        let first = try XCTUnwrap(converter.convert(tone(format: format, startFrame: 0, frames: 1024), capturedAt: 2))
        let afterGap = try XCTUnwrap(converter.convert(tone(format: format, startFrame: 1024, frames: 1024), capturedAt: 5))
        XCTAssertEqual(afterGap.start.seconds, 5, accuracy: 0.000001)
        XCTAssertGreaterThan(afterGap.start.seconds, first.end.seconds)
        converter.resetAfterFailure()
        let afterReset = try XCTUnwrap(converter.convert(tone(format: format, startFrame: 2048, frames: 1024), capturedAt: 4.999))
        XCTAssertEqual(CMTimeCompare(afterReset.start, afterGap.end), 0)
    }
    func test16BitCAFArchiveRoundTripDoesNotAttenuateRecordedSound() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WL-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try tone(format: format, startFrame: 0, frames: 48_000)
        var writer: AVAudioFile? = try PCMArchive.open(at: url, inputFormat: format)
        try writer?.write(from: input); writer = nil
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(reader.length)))
        try reader.read(into: decoded)
        var levels = PCMLevelAccumulator(); levels.append(decoded); let summary = levels.snapshotAndReset()
        XCTAssertEqual(reader.length, 48_000)
        XCTAssertEqual(summary.peak, 0.1, accuracy: 0.00004)
        XCTAssertEqual(summary.rms, 0.1 / sqrt(2), accuracy: 0.00004)
        XCTAssertEqual(summary.rmsDBFS, -23.0103, accuracy: 0.01)
    }
    func testLevelMeterCountsClippingAndHandlesSilence() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)); buffer.frameLength = 4
        let values = try XCTUnwrap(buffer.floatChannelData)[0]
        for (index, sample) in [Float(0), 0.5, 1, -1].enumerated() { values[index] = sample }
        var meter = PCMLevelAccumulator(); meter.append(buffer)
        let summary = meter.snapshotAndReset()
        XCTAssertEqual(summary.peak, 1); XCTAssertEqual(summary.rms, 0.75)
        XCTAssertEqual(summary.clippedFraction, 0.5)
        XCTAssertEqual(meter.snapshotAndReset().rmsDBFS, -120)
    }
    private func verifyResampling(inputRate: Double, inputChannels: AVAudioChannelCount, chunkSize: Int) throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: inputChannels))
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = StreamingPCMConverter(outputFormat: target)
        var output: [ConvertedPCM] = []
        for frame in stride(from: 0, to: Int(inputRate), by: chunkSize) {
            let buffer = try tone(format: inputFormat, startFrame: frame, frames: min(chunkSize, Int(inputRate) - frame))
            if let result = try converter.convert(buffer, capturedAt: 2.5 + Double(frame) / inputRate) { output.append(result) }
        }
        output += try converter.finish()
        XCTAssertFalse(output.isEmpty)
        XCTAssertEqual(try XCTUnwrap(output.first).start.seconds, 2.5, accuracy: 0.000001)
        var previous: CMTime?; var frames = 0; var meter = PCMLevelAccumulator()
        for result in output {
            XCTAssertEqual(result.buffer.format, target)
            if let previous { XCTAssertEqual(CMTimeCompare(result.start, previous), 0, "Priming/rounding must never overlap Speech input times") }
            previous = result.end; frames += Int(result.buffer.frameLength); meter.append(result.buffer)
        }
        XCTAssertEqual(Double(frames), 16_000, accuracy: 2, "Resampling and tail flush must retain one second of sound")
        XCTAssertEqual(meter.snapshotAndReset().rms, 0.1 / sqrt(2), accuracy: 0.002)
    }
    private func tone(format: AVAudioFormat, startFrame: Int, frames: Int) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))); buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<frames { samples[channel][frame] = Float(0.1 * sin(2 * Double.pi * 1000 * Double(startFrame + frame) / format.sampleRate)) }
        }
        return buffer
    }
}
