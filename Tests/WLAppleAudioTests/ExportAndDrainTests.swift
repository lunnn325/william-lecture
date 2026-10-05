import AVFoundation
import XCTest
@testable import WLAppleAudio

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class ExportAndDrainTests: XCTestCase {
    func testCaptureAdmissionDrainsAcceptedWritesAndRejectsOldGeneration() async {
        let gate = CaptureGate(); let generation = gate.open()
        let queue = DispatchQueue(label: "WL.test.audio.drain")
        let counter = LockedCounter(); let blocked = DispatchSemaphore(value: 0)
        let done = expectation(description: "Close barrier follows every admitted packet")
        queue.async { blocked.wait() }
        for _ in 0..<10000 { XCTAssertTrue(gate.offer(generation: generation) { queue.async { counter.add() } }) }
        gate.close()
        XCTAssertFalse(gate.offer(generation: generation) { XCTFail("Closed gate accepted a write") })
        queue.async { XCTAssertEqual(counter.value, 10000); done.fulfill() }
        blocked.signal(); await fulfillment(of: [done], timeout: 3)
        let resumed = gate.open()
        XCTAssertFalse(gate.offer(generation: generation) { XCTFail("Old callback crossed resume boundary") })
        XCTAssertTrue(gate.offer(generation: resumed) {})
    }
    func testM4ARoundTripPreservesPauseGapAndHandlesRateAndChannelChange() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try writeTone(root: root, index: 0, rate: 48_000, channels: 1, frames: 24000)
        let second = try writeTone(root: root, index: 1, rate: 44_100, channels: 2, frames: 22050)
        let destination = root.appendingPathComponent("lecture.m4a")
        _ = try await AudioExporter.m4a(chunks: [AudioExportChunk(url: first, start: 0), AudioExportChunk(url: second, start: 1.5)], destination: destination)
        let reader = try AVAudioFile(forReading: destination)
        XCTAssertEqual(Double(reader.length) / reader.processingFormat.sampleRate, 2, accuracy: 0.05)
        reader.framePosition = AVAudioFramePosition(reader.processingFormat.sampleRate * 0.9)
        let silent = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096))
        try reader.read(into: silent)
        var levels = PCMLevelAccumulator(); levels.append(silent)
        XCTAssertLessThan(levels.snapshotAndReset().rms, 0.001)
        reader.framePosition = AVAudioFramePosition(reader.processingFormat.sampleRate * 1.7)
        try reader.read(into: silent); levels.append(silent)
        XCTAssertGreaterThan(levels.snapshotAndReset().rms, 0.02)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
    func testBadChunkNeverPublishesPartialM4AOrDeletesOriginals() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try writeTone(root: root, index: 0, rate: 48_000, channels: 1, frames: 4096)
        let missing = root.appendingPathComponent("missing.caf"), destination = root.appendingPathComponent("lecture.m4a")
        do {
            _ = try await AudioExporter.m4a(chunks: [AudioExportChunk(url: first, start: 0), AudioExportChunk(url: missing, start: nil)], destination: destination)
            XCTFail("Incomplete export must fail")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), [first.lastPathComponent])
    }
    func testThreeHourChunkCountExportsWithBoundedStreamingBuffers() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var chunks: [AudioExportChunk] = []
        for index in 0..<360 {
            chunks.append(AudioExportChunk(url: try writeTone(root: root, index: index, rate: 48_000, channels: 1, frames: 512), start: nil))
        }
        let destination = root.appendingPathComponent("many-chunks.m4a")
        _ = try await AudioExporter.m4a(chunks: chunks, destination: destination)
        let reader = try AVAudioFile(forReading: destination)
        XCTAssertEqual(Double(reader.length), Double(360 * 512), accuracy: 2400)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func writeTone(root: URL, index: Int, rate: Double, channels: AVAudioChannelCount, frames: Int) throws -> URL {
        let url = root.appendingPathComponent("audio-\(index).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames { buffer.floatChannelData![channel][frame] = Float(0.1 * sin(2 * Double.pi * 1000 * Double(frame) / rate)) }
        }
        var writer: AVAudioFile? = try PCMArchive.open(at: url, inputFormat: format)
        try writer?.write(from: buffer); writer = nil; return url
    }
}
