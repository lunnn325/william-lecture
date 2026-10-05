import Foundation

/// Disk is the source of truth. A damaged last line after process termination is ignored.
/// Read in chunks so long sessions don't require one growing in-memory transcript.
public enum JSONLines {
    public static func append<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = try encoder.encode(value); data.append(0x0a)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw WLFailure.message("Cannot create journal")
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try repairTail(at: url)
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    private static func repairTail(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        let length = try handle.seekToEnd(); guard length > 0 else { return }
        try handle.seek(toOffset: length - 1)
        if try handle.read(upToCount: 1) == Data([0x0a]) { return }
        var position = length
        while position > 0 {
            let start = position > 65536 ? position - 65536 : 0
            try handle.seek(toOffset: start)
            let bytes = try handle.read(upToCount: Int(position - start)) ?? Data()
            if let last = bytes.lastIndex(of: 0x0a) {
                try handle.truncate(atOffset: start + UInt64(last) + 1); return
            }
            position = start
        }
        try handle.truncate(atOffset: 0)
    }
    public static func scan<T: Decodable>(_ type: T.Type, at url: URL, visit: (T) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var remainder = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            remainder.append(chunk)
            while let newline = remainder.firstIndex(of: 0x0a) {
                let line = remainder[..<newline]
                if !line.isEmpty { let value = try decoder.decode(type, from: Data(line)); try visit(value) }
                remainder.removeSubrange(...newline)
            }
            guard remainder.count < 2 * 1024 * 1024 else { throw WLFailure.message("Oversized journal line") }
        }
        // Intentionally ignore an unterminated final record, never hide malformed complete lines.
    }
}

public actor SessionStore {
    // Cache unresolved text for one active queue only. Journals remain authoritative on reopen.
    private var pendingSession: UUID?
    private var pendingIndex: [UUID: TranscriptSegment] = [:]
    public nonisolated let root: URL
    public init(root: URL) {
        self.root = root
    }
    public nonisolated func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    /// Idempotent first-launch setup. Creates missing sandbox parents as well as Sessions.
    /// Genuine storage errors (permissions, disk full, a file at this path) still propagate.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
    }
    public func availableCapacityForRecording() throws -> Int64? {
        try prepare()
        return try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }
    public func save(_ session: LectureSession) throws {
        try prepare()
        let directory = folder(session.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.appendingPathComponent("session.json").path)
        #endif
    }
    public func sessions() throws -> [LectureSession] {
        try prepare()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")) else { return nil }
                guard var session = try? decoder.decode(LectureSession.self, from: data),
                      session.id.uuidString.caseInsensitiveCompare(directory.lastPathComponent) == .orderedSame else { return nil }
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                session.audioFiles = files.filter { $0.pathExtension == "caf" }.map(\.lastPathComponent).sorted()
                return session
            }.sorted { $0.startedAt > $1.startedAt }
    }
    public func append(_ segment: TranscriptSegment, session: UUID) throws {
        try JSONLines.append(segment, to: folder(session).appendingPathComponent("transcript.jsonl"))
        if pendingSession == session {
            if segment.status == .pending || segment.status == .failed { pendingIndex[segment.id] = segment }
            else { pendingIndex.removeValue(forKey: segment.id) }
        }
    }
    public func log(_ diagnostic: Diagnostic, session: UUID) throws {
        var safe = diagnostic
        safe.fields = safe.fields.mapValues(DiagnosticRedaction.redact)
        try JSONLines.append(safe, to: folder(session).appendingPathComponent("diagnostics.jsonl"))
    }
    public func appendFinal(_ piece: SpeechPiece, session: UUID) throws {
        try JSONLines.append(piece, to: folder(session).appendingPathComponent("speech-final.jsonl"))
    }
    public func segments(_ id: UUID) throws -> [TranscriptSegment] {
        var records: [UUID: TranscriptSegment] = [:]
        try JSONLines.scan(TranscriptSegment.self, at: folder(id).appendingPathComponent("transcript.jsonl")) { records[$0.id] = $0 }
        return records.values.sorted { $0.start < $1.start }
    }
    public func pending(_ id: UUID, limit: Int = 16, retryFailed: Bool = false,
                        excluding: Set<UUID> = [], newestFirst: Bool = false) throws -> [TranscriptSegment] {
        if pendingSession != id {
            var index: [UUID: TranscriptSegment] = [:]
            try JSONLines.scan(TranscriptSegment.self, at: folder(id).appendingPathComponent("transcript.jsonl")) {
                if $0.status == .pending || $0.status == .failed { index[$0.id] = $0 }
                else { index.removeValue(forKey: $0.id) }
            }
            pendingIndex = index; pendingSession = id
        }
        let candidates = pendingIndex.values.filter {
            !excluding.contains($0.id) && ($0.status == .pending || (retryFailed && $0.status == .failed))
        }.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.id.uuidString < rhs.id.uuidString }
            return newestFirst ? lhs.start > rhs.start : lhs.start < rhs.start
        }
        return Array(candidates.prefix(max(0, limit)))
    }
    @discardableResult public func recover() throws -> [String] {
        try prepare()
        var issues: [String] = []
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let readable = try sessions()
        let readableIDs = Set(readable.map(\.id))
        for directory in directories {
            if let id = UUID(uuidString: directory.lastPathComponent), !readableIDs.contains(id) {
                issues.append("课堂 \(id) 的 metadata 无法读取；原文件保留，可从文件共享取回")
            }
        }
        for var session in readable where [.recording, .paused, .interrupted].contains(session.state) {
            do {
            session.state = .recovered
            // Include the current chunk even if the app died before its close event.
            let files = try FileManager.default.contentsOfDirectory(at: folder(session.id), includingPropertiesForKeys: nil)
            session.audioFiles = files.filter { $0.pathExtension == "caf" }.map(\.lastPathComponent).sorted()
            let savedSegments = try segments(session.id)
            let coverage = TranscriptCoverage(savedSegments)
            let lastEnd = savedSegments.map(\.end).max() ?? -1
            var lastOffset = max(session.duration, lastEnd)
            for name in ["audio-index.jsonl", "diagnostics.jsonl"] {
                try JSONLines.scan(Diagnostic.self, at: folder(session.id).appendingPathComponent(name)) {
                    if let offset = $0.offset, offset.isFinite { lastOffset = max(lastOffset, offset) }
                }
            }
            var buffer = SentenceBuffer()
            try JSONLines.scan(SpeechPiece.self, at: folder(session.id).appendingPathComponent("speech-final.jsonl")) { piece in
                if piece.end.isFinite { lastOffset = max(lastOffset, piece.end) }
                if !coverage.contains(piece), let segment = buffer.append(piece) {
                    try append(segment, session: session.id)
                }
            }
            if let tail = buffer.flush() { try append(tail, session: session.id) }
            session.duration = max(0, lastOffset)
            session.stoppedAt = session.startedAt.addingTimeInterval(session.duration)
            try save(session)
            try log(Diagnostic("process_recovery", fields: ["gap": "Recording ended when app/process terminated; audio files retained"]), session: session.id)
            } catch {
                issues.append("课堂 \(session.id) 恢复不完整：\(error.localizedDescription)；原文件保留")
            }
        }
        return issues
    }
    public func export(_ id: UUID, language: ExportLanguage, markdown: Bool) throws -> URL {
        guard let session = try sessions().first(where: { $0.id == id }) else { throw WLFailure.message("Session not found") }
        let directory = folder(id).appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("WilliamLecture-\(language.rawValue)-\(UUID().uuidString).\(markdown ? "md" : "txt")")
        let records = try segments(id)
        var lines = ["\(markdown ? "# " : "")\(session.course)", "Session: \(session.id)", "Date: \(session.startedAt.ISO8601Format())", ""]
        var gaps: [Diagnostic] = []
        try JSONLines.scan(Diagnostic.self, at: folder(id).appendingPathComponent("diagnostics.jsonl")) {
            if $0.fields["gap"] != nil { gaps.append($0) }
        }
        for record in records {
            lines.append("[\(Self.timestamp(record.start)) – \(Self.timestamp(record.end))]")
            if language != .chinese { lines.append(record.english) }
            if language != .english {
                if record.status == .mock { lines.append("[MOCK / 模拟翻译，非真实中文] \(record.chinese ?? "")") }
                else { lines.append(record.chinese ?? "[中文缺失：\(record.status.rawValue)]") }
            }
            lines.append("")
        }
        if !gaps.isEmpty {
            lines.append("\(markdown ? "## " : "")已知中断 / 缺口（未补写）")
            for gap in gaps { lines.append("[\(Self.timestamp(gap.offset ?? 0))] \(gap.event): \(gap.fields["gap"] ?? "")") }
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    /// A stable shareable file, not the journal still receiving late translation events.
    public func exportDiagnostics(_ id: UUID) throws -> URL {
        let source = folder(id).appendingPathComponent("diagnostics.jsonl")
        let directory = folder(id).appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("diagnostics-\(UUID().uuidString).jsonl")
        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: target) }
        else { try Data().write(to: target, options: .atomic) }
        return target
    }
    public func audioOffsets(_ id: UUID) throws -> [String: Double] {
        var offsets: [String: Double] = [:]
        try JSONLines.scan(Diagnostic.self, at: folder(id).appendingPathComponent("audio-index.jsonl")) {
            if ["audio_chunk_open", "audio_chunk_first_frame"].contains($0.event), let name = $0.fields["file"],
               name == URL(fileURLWithPath: name).lastPathComponent,
               let offset = $0.offset, offset.isFinite { offsets[name] = max(0, offset) }
        }
        return offsets
    }
    public nonisolated static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds)); return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
