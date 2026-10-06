import Foundation

public enum SessionState: String, Codable, Sendable { case recording, paused, stopped, interrupted, recovered }
public enum TranslationStatus: String, Codable, Sendable { case pending, completed, mock, failed }
public enum CaptionPhase: String, Sendable { case transcribing, localDraft, queuedForGPT, gptTranslating, final, failed, localOnly }
public enum ExportLanguage: String, CaseIterable, Sendable { case english, chinese, bilingual }
public enum SessionTimeline: String, Codable, Sendable { case recordedAudio }

public struct LectureSession: Codable, Identifiable, Sendable {
    public var id: UUID
    public var course: String
    public var startedAt: Date
    public var stoppedAt: Date?
    public var state: SessionState
    public var duration: Double
    /// Captured PCM seconds, excluding pauses. Nil on journals written before 0.0.6.
    public var recordedDuration: Double?
    /// Nil means a legacy session with wall-time offsets, including pause gaps.
    public var timeline: SessionTimeline?
    public var usesRecordingTimeline: Bool { timeline == .recordedAudio }
    public var recordingSeconds: Double { max(0, recordedDuration ?? 0) }
    public var audioFiles: [String]
    public init(course: String, now: Date = Date()) {
        id = UUID(); self.course = course; startedAt = now
        state = .recording; duration = 0; recordedDuration = 0; timeline = .recordedAudio; audioFiles = []
    }
    public mutating func updateRecordingDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        recordedDuration = max(recordingSeconds, seconds)
        if usesRecordingTimeline { duration = recordingSeconds }
    }
    /// New sessions share one captured-audio axis across the timer, Speech and exports.
    public func timelineOffset(now: Date = Date()) -> Double {
        if usesRecordingTimeline { return recordingSeconds }
        return [.stopped, .recovered].contains(state) ? duration : max(0, now.timeIntervalSince(startedAt))
    }
}

public struct TranscriptSegment: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var english: String
    public var chinese: String?
    public var status: TranslationStatus
    public var receivedAt: Date
    /// Real capture date, independent of the pause-free audio position.
    public var audioEndedAt: Date?
    /// Buffer emission time; optional so existing on-device journals remain readable.
    public var queuedAt: Date?
    public var submittedAt: Date?
    public var firstTranslationAt: Date?
    public var completedAt: Date?
    public var attempts: Int
    public var error: String?
    public var revision: Int?
    public var partialFirstAt: Date?
    public var localEnabled: Bool?
    public var localChinese: String?
    public var localSourceText: String?
    public var localRevision: Int?
    public var localFirstAt: Date?
    public var localCompletedAt: Date?
    public var localDisplayedAt: Date?
    public var localAttemptedRevision: Int?
    public var localRequestID: UUID?
    public var localError: String?
    public var gptRevision: Int?
    public var gptRequestID: UUID?
    public var gptDeferred: Bool?
    public var sourceRevision: Int { max(1, revision ?? 1) }
    public var validLocalChinese: String? {
        guard localRevision == sourceRevision, CaptionSource.normalized(localSourceText ?? "") == CaptionSource.normalized(english),
              let localChinese, !localChinese.isEmpty else { return nil }
        return localChinese
    }
    public var finalChinese: String? {
        status == .completed && (gptRevision ?? sourceRevision) == sourceRevision ? chinese : nil
    }
    public var displayChinese: String? { finalChinese ?? validLocalChinese ?? chinese }
    public var exportChinese: String? { finalChinese ?? validLocalChinese ?? (status == .mock ? chinese : nil) }
    public var phase: CaptionPhase {
        if finalChinese != nil { return .final }
        if validLocalChinese != nil && (status == .failed || gptDeferred == true || error != nil) { return .localOnly }
        if status == .pending && submittedAt != nil && gptRequestID != nil { return .gptTranslating }
        if validLocalChinese != nil { return .localDraft }
        return status == .failed ? .failed : .queuedForGPT
    }
    /// Actor writes are authoritative; callbacks can arrive in the opposite order.
    /// Merge display snapshots without ever writing an in-memory stream to disk.
    public func mergingDisplay(_ prior: TranscriptSegment) -> TranscriptSegment {
        guard id == prior.id else { return self }
        if sourceRevision < prior.sourceRevision { return prior }
        guard sourceRevision == prior.sourceRevision, english == prior.english else { return self }
        var merged = self
        if (prior.localCompletedAt ?? .distantPast) > (localCompletedAt ?? .distantPast) {
            merged.localChinese = prior.localChinese; merged.localSourceText = prior.localSourceText
            merged.localRevision = prior.localRevision; merged.localCompletedAt = prior.localCompletedAt
        }
        merged.localFirstAt = [localFirstAt, prior.localFirstAt].compactMap { $0 }.min()
        merged.localDisplayedAt = [localDisplayedAt, prior.localDisplayedAt].compactMap { $0 }.min()
        if (prior.finalChinese != nil && finalChinese == nil) ||
            (prior.submittedAt ?? .distantPast) > (submittedAt ?? .distantPast) {
            merged.chinese = prior.chinese; merged.status = prior.status; merged.error = prior.error
            merged.gptRevision = prior.gptRevision; merged.gptRequestID = prior.gptRequestID
            merged.submittedAt = prior.submittedAt; merged.firstTranslationAt = prior.firstTranslationAt
            merged.completedAt = prior.completedAt; merged.attempts = prior.attempts
        } else if status == .pending, error == nil, chinese == nil, gptRequestID == prior.gptRequestID {
            merged.chinese = prior.chinese // retain a visible stream across a local-only callback
        }
        return merged
    }
    public init(start: Double, end: Double, english: String, receivedAt: Date = Date()) {
        id = UUID(); self.start = max(0, start); self.end = max(start, end)
        self.english = english; self.receivedAt = receivedAt; status = .pending; attempts = 0
    }
    public func audioEndDate(in session: LectureSession) -> Date? {
        if let audioEndedAt { return audioEndedAt }
        return session.usesRecordingTimeline ? nil : session.startedAt.addingTimeInterval(end)
    }
}

public struct SpeechPiece: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var receivedAt: Date
    public var audioStartedAt: Date?
    public var audioEndedAt: Date?
    public init(text: String, start: Double, end: Double, receivedAt: Date = Date(), audioStartedAt: Date? = nil, audioEndedAt: Date? = nil) {
        self.text = text; self.start = start; self.end = end; self.receivedAt = receivedAt
        self.audioStartedAt = audioStartedAt; self.audioEndedAt = audioEndedAt
    }
}

/// Consumes finalized Speech results only. Volatile text is display-only.
/// The quiet timer is a batching timer, never evidence that a volatile result is final.
public struct SentenceBuffer: Sendable {
    private var pieces: [SpeechPiece] = []
    public private(set) var pendingID = UUID()
    public var pendingText: String { pieces.map(\.text).joined(separator: " ") }
    public var pendingStart: Double? { pieces.first?.start }
    public var pendingEnd: Double? { pieces.last?.end }
    private var lastRangeEnd: Double = -1
    public let maxWords: Int
    public let quietSeconds: Double
    public let maxAudioSeconds: Double
    public var quietDeadline: Date? { pieces.last?.receivedAt.addingTimeInterval(quietSeconds) }
    public init(maxWords: Int = 20, quietSeconds: Double = 0.35, maxAudioSeconds: Double = 4.5) {
        self.maxWords = maxWords; self.quietSeconds = quietSeconds; self.maxAudioSeconds = maxAudioSeconds
    }
    public mutating func append(_ piece: SpeechPiece) -> TranscriptSegment? {
        guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              piece.end > lastRangeEnd + 0.001 else { return nil }
        lastRangeEnd = piece.end
        pieces.append(piece)
        let text = pieces.map(\.text).joined(separator: " ")
        if text.split(whereSeparator: { $0.isWhitespace }).count >= maxWords ||
            piece.end - (pieces.first?.start ?? piece.start) >= maxAudioSeconds ||
            ".!?。！？".contains(text.last ?? " ") { return flush() }
        return nil
    }
    public mutating func flushIfQuiet(now: Date) -> TranscriptSegment? {
        guard let last = pieces.last, now.timeIntervalSince(last.receivedAt) >= quietSeconds else { return nil }
        return flush()
    }
    public mutating func flush() -> TranscriptSegment? {
        guard let first = pieces.first, let last = pieces.last else { return nil }
        var result = TranscriptSegment(start: first.start, end: last.end,
            english: pieces.map(\.text).joined(separator: " "), receivedAt: last.receivedAt)
        result.id = pendingID; pendingID = UUID()
        result.audioEndedAt = last.audioEndedAt
        pieces.removeAll(keepingCapacity: true)
        return result
    }
}

/// Maps audio positions back to real capture dates for latency measurements.
/// Store an anchor only when the physical clock changes by at least 50 ms;
/// a continuous multi-hour run needs one anchor rather than one per PCM packet.
public struct AudioCaptureDates: Sendable {
    private struct Anchor: Sendable { let offset: Double; let at: Date }
    private var anchors: [Anchor] = []
    public var anchorCount: Int { anchors.count }
    public init() {}
    public mutating func observe(offset: Double, capturedAt: Date) {
        guard offset.isFinite, offset >= 0, capturedAt.timeIntervalSince1970.isFinite else { return }
        if let last = anchors.last {
            guard offset > last.offset else { return }
            let predicted = last.at.addingTimeInterval(offset - last.offset)
            if abs(predicted.timeIntervalSince(capturedAt)) < 0.05 { return }
        }
        anchors.append(Anchor(offset: offset, at: capturedAt))
    }
    public func date(at offset: Double) -> Date? {
        guard offset.isFinite, let first = anchors.first else { return nil }
        let anchor = anchors.last(where: { $0.offset <= offset }) ?? first
        return anchor.at.addingTimeInterval(offset - anchor.offset)
    }
}

public struct Diagnostic: Codable, Sendable {
    public var at: Date
    public var event: String
    public var offset: Double?
    public var fields: [String: String]
    public init(_ event: String, offset: Double? = nil, fields: [String: String] = [:], at: Date = Date()) {
        self.at = at; self.event = event; self.offset = offset; self.fields = fields
    }
}

public enum WLFailure: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
