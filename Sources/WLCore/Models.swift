import Foundation

public enum SessionState: String, Codable, Sendable { case recording, paused, stopped, interrupted, recovered }
public enum TranslationStatus: String, Codable, Sendable { case pending, completed, mock, failed }
public enum ExportLanguage: String, CaseIterable, Sendable { case english, chinese, bilingual }

public struct LectureSession: Codable, Identifiable, Sendable {
    public var id: UUID
    public var course: String
    public var startedAt: Date
    public var stoppedAt: Date?
    public var state: SessionState
    public var duration: Double
    public var audioFiles: [String]
    public init(course: String, now: Date = Date()) {
        id = UUID(); self.course = course; startedAt = now
        state = .recording; duration = 0; audioFiles = []
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
    public var submittedAt: Date?
    public var firstTranslationAt: Date?
    public var completedAt: Date?
    public var attempts: Int
    public var error: String?
    public init(start: Double, end: Double, english: String, receivedAt: Date = Date()) {
        id = UUID(); self.start = max(0, start); self.end = max(start, end)
        self.english = english; self.receivedAt = receivedAt; status = .pending; attempts = 0
    }
}

public struct SpeechPiece: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var receivedAt: Date
    public init(text: String, start: Double, end: Double, receivedAt: Date = Date()) {
        self.text = text; self.start = start; self.end = end; self.receivedAt = receivedAt
    }
}

/// Consumes finalized Speech results only. Volatile text is display-only.
/// The quiet timer is a batching timer, never evidence that a volatile result is final.
public struct SentenceBuffer: Sendable {
    private var pieces: [SpeechPiece] = []
    private var lastRangeEnd: Double = -1
    public let maxWords: Int
    public let quietSeconds: Double
    public init(maxWords: Int = 28, quietSeconds: Double = 0.8) {
        self.maxWords = maxWords; self.quietSeconds = quietSeconds
    }
    public mutating func append(_ piece: SpeechPiece) -> TranscriptSegment? {
        guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              piece.end > lastRangeEnd + 0.001 else { return nil }
        lastRangeEnd = piece.end
        pieces.append(piece)
        let text = pieces.map(\.text).joined(separator: " ")
        if text.split(whereSeparator: { $0.isWhitespace }).count >= maxWords ||
            ".!?。！？".contains(text.last ?? " ") { return flush() }
        return nil
    }
    public mutating func flushIfQuiet(now: Date) -> TranscriptSegment? {
        guard let last = pieces.last, now.timeIntervalSince(last.receivedAt) >= quietSeconds else { return nil }
        return flush()
    }
    public mutating func flush() -> TranscriptSegment? {
        guard let first = pieces.first, let last = pieces.last else { return nil }
        let result = TranscriptSegment(start: first.start, end: last.end,
            english: pieces.map(\.text).joined(separator: " "), receivedAt: last.receivedAt)
        pieces.removeAll(keepingCapacity: true)
        return result
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
