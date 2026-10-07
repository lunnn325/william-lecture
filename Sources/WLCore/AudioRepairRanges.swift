import Foundation

public struct AudioRepairRange: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    /// Audio after the last word is often silence, not lost transcription.
    public static func unfinishedTail(finalEnd: Double, audioEnd: Double, partial: SpeechPiece?, failed: Bool) -> AudioRepairRange? {
        let start = max(0, finalEnd)
        guard audioEnd.isFinite, audioEnd > start + 0.1 else { return nil }
        if failed { return .init(start: start, end: audioEnd) }
        guard let partial, partial.end > start + 0.1,
              !partial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .init(start: start, end: min(audioEnd, partial.end))
    }
    public static func uncovered(_ ranges: [AudioRepairRange], covered: [AudioRepairRange]) -> [AudioRepairRange] {
        var merged: [AudioRepairRange] = []
        for r in ranges.filter({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, r.start <= last.end + 0.05 { merged[merged.count - 1].end = max(last.end, r.end) }
            else { merged.append(r) }
        }
        for c in covered {
            merged = merged.flatMap { r -> [AudioRepairRange] in
                if c.end <= r.start || c.start >= r.end { return [r] }
                var result: [AudioRepairRange] = []
                if c.start > r.start { result.append(.init(start: r.start, end: min(c.start, r.end))) }
                if c.end < r.end { result.append(.init(start: max(c.end, r.start), end: r.end)) }
                return result
            }
        }
        return merged.filter { $0.end - $0.start > 0.05 }
    }
}
extension SessionStore {
    public func audioRepairRanges(_ id: UUID) throws -> [AudioRepairRange] {
        try requireSession(id)
        var gaps: [AudioRepairRange] = [], done: [AudioRepairRange] = []
        try JSONLines.scan(Diagnostic.self, at: folder(id).appendingPathComponent("diagnostics.jsonl")) { item in
            guard let start = item.fields["range_start"].flatMap(Double.init), let end = item.fields["range_end"].flatMap(Double.init) else { return }
            if ["speech_input_gap", "speech_unfinalized_tail"].contains(item.event) { gaps.append(.init(start: start, end: end)) }
            if item.event == "speech_gap_repaired" { done.append(.init(start: start, end: end)) }
        }
        let coverage = try segments(id).map { AudioRepairRange(start: $0.start, end: $0.end) }
        return AudioRepairRange.uncovered(gaps, covered: done + coverage)
    }
    public func appendRepaired(_ source: TranscriptSegment, session id: UUID) throws -> Bool {
        guard try sessionMetadata(id).allowsAudioUse, !Task.isCancelled, source.end > source.start,
              !((try segments(id)).contains { $0.start < source.end - 0.02 && $0.end > source.start + 0.02 }) else { return false }
        try append(source, session: id); return true
    }
}
