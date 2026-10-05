import Foundation

public struct FinalSpeechCursor: Sendable {
    public private(set) var end = -1.0
    public init() {}
    public mutating func accept(_ piece: SpeechPiece) -> Bool {
        guard piece.start.isFinite, piece.end.isFinite, piece.start >= 0, piece.end >= piece.start,
              !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              piece.end > end + 0.001 else { return false }
        end = piece.end; return true
    }
}

/// Recovery checks coverage rather than just the latest segment end, retaining interior holes.
struct TranscriptCoverage {
    private var ranges: [(start: Double, end: Double)] = []
    init(_ segments: [TranscriptSegment]) {
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if let last = ranges.last, segment.start <= last.end + 0.001 {
                ranges[ranges.count - 1].end = max(last.end, segment.end)
            } else { ranges.append((segment.start, segment.end)) }
        }
    }
    func contains(_ piece: SpeechPiece) -> Bool {
        var lower = 0, upper = ranges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if ranges[middle].start <= piece.start + 0.001 { lower = middle + 1 }
            else { upper = middle }
        }
        return lower > 0 && ranges[lower - 1].end >= piece.end - 0.001
    }
}
