import Foundation

public enum CaptionSource {
    public static func normalized(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    public static func isPrefix(_ prefix: String, of text: String) -> Bool {
        let old = normalized(prefix), new = normalized(text)
        return !old.isEmpty && (old == new || new.hasPrefix(old + " "))
    }
}

public struct DraftTranslationRequest: Sendable, Equatable {
    public let sessionID: UUID
    public let captionID: UUID
    public let epoch: UUID
    public let revision: Int
    public let english: String
    public let start: Double
    public let end: Double
    public let partialFirstAt: Date
    public init(sessionID: UUID, captionID: UUID, epoch: UUID, revision: Int, english: String,
                start: Double, end: Double, partialFirstAt: Date) {
        self.sessionID = sessionID; self.captionID = captionID; self.epoch = epoch; self.revision = revision
        self.english = english; self.start = start; self.end = end; self.partialFirstAt = partialFirstAt
    }
}

public enum DraftAcceptance: String, Sendable { case exact, prefix, stale }

/// Display-only English. Apple hypotheses can overlap finalized audio; show the
/// latest hypothesis intact rather than waiting for a safe translation boundary.
/// This never changes the finalized buffer, revision checks or transcript journal.
public enum LiveEnglishPreview {
    public static func text(partial: SpeechPiece?, buffer: SentenceBuffer, finalizedEnd: Double) -> String? {
        guard let partial, partial.end > finalizedEnd + 0.001 else { return nil }
        let text = CaptionSource.normalized(partial.text)
        guard !text.isEmpty else { return nil }
        guard let end = buffer.pendingEnd, end <= partial.start + 0.001 else { return text }
        return CaptionSource.normalized([buffer.pendingText, text].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

public struct LiveCaption: Sendable {
    public let id: UUID
    public var revision: Int
    public var english: String
    public var start: Double
    public var end: Double
    public var firstPartialAt: Date
    public var chinese: String?
    public var localSource: String?
    public var localRevision = 0
    public var correctionFloor = 1
    public var localFirstAt: Date?
    public var localCompletedAt: Date?
    public var localDisplayedAt: Date?
    public var phase: CaptionPhase { chinese == nil ? .transcribing : .localDraft }
}

/// UI-only revisions. Only freeze() can transfer an exact full-source draft to a journaled segment.
public struct CaptionDraftCoordinator: Sendable {
    public private(set) var current: LiveCaption?
    private var volatile: SpeechPiece?
    private var epoch = UUID()
    public init() {}
    public mutating func replacePartial(_ piece: SpeechPiece) { volatile = piece.text.isEmpty ? nil : piece }
    public mutating func acceptedFinal(_ piece: SpeechPiece) {
        // Plain String carries no safe character-to-time cut. Revoke an overlapping cached partial.
        if let volatile, volatile.start < piece.end - 0.001 { self.volatile = nil }
    }
    public mutating func refresh(buffer: SentenceBuffer, finalizedEnd: Double, now: Date = Date()) {
        if let volatile, volatile.start < finalizedEnd - 0.001 { self.volatile = nil }
        let source = CaptionSource.normalized([buffer.pendingText, volatile?.text ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
        guard !source.isEmpty else { current = nil; epoch = UUID(); return }
        let start = buffer.pendingStart ?? volatile?.start ?? 0
        let end = max(buffer.pendingEnd ?? 0, volatile?.end ?? 0)
        if var current, current.id == buffer.pendingID {
            if current.english != source {
                current.revision += 1
                if !CaptionSource.isPrefix(current.english, of: source) { current.correctionFloor = current.revision }
                current.english = source
            }
            current.start = start; current.end = end; self.current = current
        } else {
            current = LiveCaption(id: buffer.pendingID, revision: 1, english: source, start: start, end: end,
                                  firstPartialAt: volatile?.receivedAt ?? now)
        }
    }
    public func request(session: UUID) -> DraftTranslationRequest? {
        guard let current, current.localSource != current.english else { return nil }
        return DraftTranslationRequest(sessionID: session, captionID: current.id, epoch: epoch, revision: current.revision,
            english: current.english, start: current.start, end: current.end, partialFirstAt: current.firstPartialAt)
    }
    public mutating func accept(_ request: DraftTranslationRequest, text: String, at: Date) -> DraftAcceptance {
        guard var current, request.epoch == epoch, request.captionID == current.id, !text.isEmpty,
              request.revision >= current.localRevision else { return .stale }
        let exact = request.revision == current.revision && request.english == current.english
        // A correction that was later reverted is still a different revision; only growing prefixes qualify.
        guard exact || (request.revision >= current.correctionFloor && request.revision < current.revision && CaptionSource.isPrefix(request.english, of: current.english)) else { return .stale }
        current.chinese = text; current.localSource = request.english; current.localRevision = request.revision
        current.localFirstAt = current.localFirstAt ?? at; current.localCompletedAt = at; self.current = current
        return exact ? .exact : .prefix
    }
    public mutating func freeze(_ segment: TranscriptSegment) -> TranscriptSegment {
        var segment = segment
        if let current, current.id == segment.id {
            segment.revision = current.revision + (current.english == CaptionSource.normalized(segment.english) ? 0 : 1)
            segment.partialFirstAt = current.firstPartialAt; segment.localFirstAt = current.localFirstAt
            segment.localDisplayedAt = current.localDisplayedAt
            if current.localSource == CaptionSource.normalized(segment.english), let chinese = current.chinese {
                segment.localChinese = chinese; segment.localSourceText = segment.english
                segment.localRevision = segment.sourceRevision; segment.localCompletedAt = current.localCompletedAt
            }
        } else { segment.revision = 1 }
        return segment
    }
    public mutating func markDisplayed(id: UUID, at: Date) -> Bool {
        guard var current, current.id == id, current.chinese != nil, current.localDisplayedAt == nil else { return false }
        current.localDisplayedAt = at; self.current = current; return true
    }
    public mutating func invalidate() { volatile = nil; current = nil; epoch = UUID() }
}
