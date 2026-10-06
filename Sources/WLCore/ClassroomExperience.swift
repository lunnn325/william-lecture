import Foundation

/// Separate annotation journal: user writing must never replace recognized speech.
public struct LectureNote: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var segmentID: UUID?
    public var offset: Double
    public var englishSnapshot: String
    public var text: String
    public var marked: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var isActive: Bool { marked || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public init(segmentID: UUID? = nil, offset: Double, english: String = "", text: String = "", marked: Bool = true, now: Date = Date()) {
        id = UUID(); self.segmentID = segmentID; self.offset = offset.isFinite ? max(0, offset) : 0
        englishSnapshot = english; self.text = text; self.marked = marked; createdAt = now; updatedAt = now
    }
}

public extension SessionStore {
    func notes(_ session: UUID) throws -> [LectureNote] {
        var latest: [UUID: LectureNote] = [:]
        try JSONLines.scan(LectureNote.self, at: folder(session).appendingPathComponent("notes.jsonl")) { latest[$0.id] = $0 }
        return latest.values.filter(\.isActive).sorted { $0.offset == $1.offset ? $0.createdAt < $1.createdAt : $0.offset < $1.offset }
    }
    func saveNote(_ note: LectureNote, session: UUID) throws {
        guard note.offset.isFinite, note.offset >= 0, note.text.count <= 6000,
              FileManager.default.fileExists(atPath: folder(session).appendingPathComponent("session.json").path) else {
            throw WLFailure.message("笔记无法保存，请检查课堂记录和内容长度")
        }
        try JSONLines.append(note, to: folder(session).appendingPathComponent("notes.jsonl"))
    }
    func exportNotes(_ session: UUID, markdown: Bool) throws -> URL {
        let directory = folder(session).appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("WilliamLecture-notes-\(UUID().uuidString).\(markdown ? "md" : "txt")")
        var lines = [markdown ? "# 课堂标记与笔记" : "课堂标记与笔记", "记录时原文是标记快照，可能尚未定稿；正式文字稿另行导出。", ""]
        for note in try notes(session) {
            lines.append("[\(Self.timestamp(note.offset))]\(note.marked ? " · 已标记" : "")")
            if !note.englishSnapshot.isEmpty { lines.append("记录时原文：\(note.englishSnapshot)") }
            if !note.text.isEmpty { lines.append(note.text) }
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Presentation window only. Reading freezes its membership, while updating visible
/// translations in place. New records continue to be persisted by the unchanged engine.
public struct CaptionFeed: Sendable {
    public private(set) var rows: [TranscriptSegment] = []
    public private(set) var following = true
    public private(set) var hasNewContent = false
    public let limit: Int
    public init(limit: Int = 180) { self.limit = max(30, limit) }
    public mutating func suspend() { following = false }
    public mutating func merge(_ incoming: [TranscriptSegment]) {
        var index = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for segment in incoming {
            if let prior = index[segment.id] { index[segment.id] = segment.mergingDisplay(prior) }
            else if following { index[segment.id] = segment }
            else { hasNewContent = true }
        }
        rows = index.values.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        if following && rows.count > limit { rows.removeFirst(rows.count - limit) }
    }
    public mutating func resume(latest: [TranscriptSegment]) {
        following = true; hasNewContent = false; rows = []; merge(latest)
    }
    public mutating func prepend(_ older: [TranscriptSegment]) {
        following = false
        let existing = Set(rows.map(\.id))
        var unique: [UUID: TranscriptSegment] = [:]
        for segment in older where !existing.contains(segment.id) { unique[segment.id] = segment.mergingDisplay(unique[segment.id] ?? segment) }
        rows = unique.values.sorted { $0.start < $1.start } + rows
        // Bound the reading snapshot as well. Older-page loading never adds newest traffic.
        if rows.count > limit * 2 { rows.removeLast(rows.count - limit * 2) }
    }
}

public struct PlaybackSlice: Equatable, Sendable {
    public let file: String
    public let start: Double
    public let duration: Double
    public init(file: String, start: Double, duration: Double) { self.file = file; self.start = start; self.duration = duration }
}
public struct PlaybackPosition: Equatable, Sendable {
    public let index: Int
    public let fileSeconds: Double
}
public struct PlaybackTimeline: Sendable {
    public let slices: [PlaybackSlice]
    public var duration: Double { slices.last.map { $0.start + $0.duration } ?? 0 }
    public init(slices: [PlaybackSlice]) throws {
        var end = 0.0
        for slice in slices {
            guard slice.start.isFinite, slice.duration.isFinite, slice.start >= end - 0.001, slice.duration > 0,
                  slice.file == URL(fileURLWithPath: slice.file).lastPathComponent else { throw WLFailure.message("录音时间信息不完整，原始音频保留") }
            end = slice.start + slice.duration
        }
        self.slices = slices
    }
    public func position(at seconds: Double) -> PlaybackPosition? {
        guard seconds.isFinite, !slices.isEmpty else { return nil }
        let target = min(duration, max(0, seconds))
        // A legacy pause gap seeks to the next actual recorded frame, never fabricates audio.
        let index = slices.firstIndex(where: { target < $0.start + $0.duration }) ?? slices.count - 1
        return PlaybackPosition(index: index, fileSeconds: min(slices[index].duration, max(0, target - slices[index].start)))
    }
}
