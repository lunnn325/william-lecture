import Foundation

public struct LookupSelection: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let captionID: UUID
    public let revision: Int
    public let source: String
    public let range: NSRange
    public let term: String
    public init(sessionID: UUID, captionID: UUID, revision: Int, source: String, ranges: [NSRange]) throws {
        guard ranges.count == 1, let range = ranges.first, range.location != NSNotFound,
              range.location >= 0, range.length > 0, range.location <= source.utf16.count,
              range.length <= source.utf16.count - range.location,
              let swiftRange = Range(range, in: source) else { throw WLFailure.message("请选择文本") }
        let term = String(source[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw WLFailure.message("请选择文本") }
        guard term.count <= 120, term.split(whereSeparator: { $0.isWhitespace }).count <= 10 else {
            throw WLFailure.message("请选择更短的词语")
        }
        id = UUID(); self.sessionID = sessionID; self.captionID = captionID; self.revision = revision
        self.source = source; self.range = range; self.term = term
    }
}

/// Display-only lookup identity. Closing or selecting again revokes every old callback.
public struct LookupRequestGate: Sendable {
    public private(set) var selection: LookupSelection?
    private var token = UUID()
    public init() {}
    public mutating func select(_ selection: LookupSelection) { self.selection = selection; token = UUID() }
    public mutating func begin() -> UUID { token = UUID(); return token }
    public func accepts(_ request: UUID, selection: UUID) -> Bool { token == request && self.selection?.id == selection }
    public mutating func close() { token = UUID(); selection = nil }
}

public struct LookupSpeechState: Sendable {
    public private(set) var speaking = false
    public init() {}
    public mutating func begin(recordingState: SessionState?, busy: Bool) -> Bool {
        guard !busy, recordingState == nil || recordingState == .paused || recordingState == .stopped || recordingState == .recovered else { return false }
        speaking = true; return true
    }
    public mutating func stopBeforeRecording() { speaking = false }
}
