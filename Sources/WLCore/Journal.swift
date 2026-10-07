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
    // One selected classroom, loaded once. This index merges concurrent translator field updates;
    // it never replaces the incrementally written journal and is discarded on a classroom switch.
    private var translationSession: UUID?
    private var translationIndex: [UUID: TranscriptSegment] = [:]
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
        guard !isDeleted(session.id) else { throw WLFailure.message("课堂记录已删除") }
        let directory = try checkedFolder(session.id)
        var session = session
        if let current = try? sessionMetadata(session.id), !current.allowsAudioUse {
            // Audio cleanup is monotonic, even if a late lifecycle snapshot is saved.
            session.audioStorage = current.audioStorage == .cleared || session.audioStorage == .cleared ? .cleared : .clearing
            session.audioFiles = []
        }
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
                guard let id = UUID(uuidString: directory.lastPathComponent), !isDeleted(id), (try? checkedFolder(id)) != nil else { return nil }
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")) else { return nil }
                guard var session = try? decoder.decode(LectureSession.self, from: data),
                      session.id.uuidString.caseInsensitiveCompare(directory.lastPathComponent) == .orderedSame else { return nil }
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                session.audioFiles = session.allowsAudioUse ? files.filter { $0.pathExtension == "caf" }.map(\.lastPathComponent).sorted() : []
                return session
            }.sorted { $0.startedAt > $1.startedAt }
    }
    public func append(_ segment: TranscriptSegment, session: UUID) throws {
        try requireSession(session)
        try JSONLines.append(segment, to: folder(session).appendingPathComponent("transcript.jsonl"))
        if translationSession == session { translationIndex[segment.id] = segment }
        if pendingSession == session {
            if segment.status == .pending || segment.status == .failed { pendingIndex[segment.id] = segment }
            else { pendingIndex.removeValue(forKey: segment.id) }
        }
    }
    private func loadTranslationIndex(_ session: UUID) throws {
        try requireSession(session)
        guard translationSession != session else { return }
        var index: [UUID: TranscriptSegment] = [:]
        try JSONLines.scan(TranscriptSegment.self, at: folder(session).appendingPathComponent("transcript.jsonl")) { index[$0.id] = $0 }
        translationIndex = index; translationSession = session
    }
    public func translationSnapshot(_ source: TranscriptSegment, session: UUID) throws -> TranscriptSegment? {
        try loadTranslationIndex(session)
        guard let current = translationIndex[source.id], current.sourceRevision == source.sourceRevision,
              current.english == source.english else { return nil }
        return current
    }
    public func englishContext(_ source: TranscriptSegment, session: UUID) throws -> String {
        try loadTranslationIndex(session)
        return String(translationIndex.values.filter { $0.id != source.id && $0.end <= source.start + 0.001 && $0.end >= source.start - 30 }
            .sorted { $0.start < $1.start }.map(\.english).joined(separator: " ").suffix(6000))
    }
    public func beginGPT(_ source: TranscriptSegment, session: UUID, request: UUID, at: Date) throws -> TranscriptSegment? {
        guard !Task.isCancelled, var current = try translationSnapshot(source, session: session),
              current.status == .pending || current.status == .failed else { return nil }
        current.gptRequestID = request; current.gptRevision = current.sourceRevision
        current.attempts += 1; current.submittedAt = at; current.firstTranslationAt = nil; current.completedAt = nil
        current.chinese = nil; current.error = nil; current.status = .pending; current.gptDeferred = false
        return try commitTranslation(current, session: session)
    }
    public func applyGPT(_ source: TranscriptSegment, session: UUID, request: UUID, status: TranslationStatus,
                         chinese: String? = nil, firstAt: Date? = nil, completedAt: Date? = nil, error: String? = nil) throws -> TranscriptSegment? {
        guard !Task.isCancelled, var current = try translationSnapshot(source, session: session), current.gptRequestID == request,
              current.status == .pending else { return nil }
        current.status = status; current.chinese = chinese; current.firstTranslationAt = firstAt
        current.completedAt = completedAt; current.error = error
        if status != .pending || error != nil { current.gptRequestID = nil }
        return try commitTranslation(current, session: session)
    }
    public func cancelGPT(_ source: TranscriptSegment, session: UUID, request: UUID) throws -> TranscriptSegment? {
        guard var current = try translationSnapshot(source, session: session), current.gptRequestID == request,
              current.status == .pending else { return nil }
        current.gptRequestID = nil; current.submittedAt = nil; current.chinese = nil; current.error = "翻译请求已取消"
        return try commitTranslation(current, session: session)
    }
    public func localPending(_ session: UUID, newestFirst: Bool = false) throws -> TranscriptSegment? {
        try loadTranslationIndex(session)
        return translationIndex.values.filter {
            $0.localEnabled == true && $0.validLocalChinese == nil && $0.finalChinese == nil && $0.localAttemptedRevision != $0.sourceRevision
        }.sorted { newestFirst ? $0.start > $1.start : $0.start < $1.start }.first
    }
    public func beginLocal(_ source: TranscriptSegment, session: UUID, request: UUID) throws -> TranscriptSegment? {
        guard !Task.isCancelled, var current = try translationSnapshot(source, session: session), current.localEnabled == true,
              current.validLocalChinese == nil, current.finalChinese == nil, current.localAttemptedRevision != current.sourceRevision else { return nil }
        current.localRequestID = request; current.localAttemptedRevision = current.sourceRevision; current.localError = nil
        return try commitTranslation(current, session: session)
    }
    public func applyLocal(_ source: TranscriptSegment, session: UUID, request: UUID, chinese: String?, at: Date, error: String? = nil) throws -> TranscriptSegment? {
        guard !Task.isCancelled, var current = try translationSnapshot(source, session: session), current.localRequestID == request else { return nil }
        current.localError = error
        current.localRequestID = nil
        if let chinese, !chinese.isEmpty {
            current.localChinese = chinese; current.localSourceText = current.english; current.localRevision = current.sourceRevision
            current.localFirstAt = current.localFirstAt ?? at; current.localCompletedAt = at
        }
        return try commitTranslation(current, session: session)
    }
    public func cancelLocal(_ source: TranscriptSegment, session: UUID, request: UUID) throws {
        guard var current = try translationSnapshot(source, session: session), current.localRequestID == request else { return }
        current.localRequestID = nil; current.localAttemptedRevision = nil
        _ = try commitTranslation(current, session: session)
    }
    public func resetLocalFailures(_ session: UUID) throws {
        try loadTranslationIndex(session)
        for var current in Array(translationIndex.values) where current.localEnabled == true && current.validLocalChinese == nil && current.finalChinese == nil {
            current.localAttemptedRevision = nil; current.localRequestID = nil; current.localError = nil
            _ = try commitTranslation(current, session: session)
        }
    }
    public func markLocalDisplayed(_ source: TranscriptSegment, session: UUID, at: Date) throws {
        guard var current = try translationSnapshot(source, session: session), current.localDisplayedAt == nil else { return }
        current.localDisplayedAt = at; _ = try commitTranslation(current, session: session)
    }
    public func requeueGPT(_ session: UUID, includeMock: Bool) throws {
        try loadTranslationIndex(session)
        for var current in Array(translationIndex.values) where current.status == .failed || (includeMock && current.status == .mock) {
            current.status = .pending; current.error = nil; current.gptRequestID = nil
            current.chinese = nil; current.submittedAt = nil; current.completedAt = nil
            _ = try commitTranslation(current, session: session)
        }
    }
    private func commitTranslation(_ source: TranscriptSegment, session: UUID) throws -> TranscriptSegment {
        var current = source
        current.translationUpdate = (translationIndex[source.id]?.translationUpdate ?? 0) + 1
        try append(current, session: session)
        return current
    }
    public func log(_ diagnostic: Diagnostic, session: UUID) throws {
        try requireSession(session)
        var safe = diagnostic
        safe.fields = safe.fields.mapValues(DiagnosticRedaction.redact)
        try JSONLines.append(safe, to: folder(session).appendingPathComponent("diagnostics.jsonl"))
    }
    public func appendFinal(_ piece: SpeechPiece, session: UUID) throws {
        try requireSession(session)
        try JSONLines.append(piece, to: folder(session).appendingPathComponent("speech-final.jsonl"))
    }
    public func segments(_ id: UUID) throws -> [TranscriptSegment] {
        try requireSession(id)
        var records: [UUID: TranscriptSegment] = [:]
        try JSONLines.scan(TranscriptSegment.self, at: folder(id).appendingPathComponent("transcript.jsonl")) { records[$0.id] = $0 }
        return records.values.sorted { $0.start < $1.start }
    }
    public func pending(_ id: UUID, limit: Int = 16, retryFailed: Bool = false,
                        excluding: Set<UUID> = [], newestFirst: Bool = false) throws -> [TranscriptSegment] {
        try requireSession(id)
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
        var issues = try recoverLibraryCleanup()
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let readable = try sessions()
        var damagedTranscripts: Set<UUID> = []
        // No provider tasks survive process death, including tasks left after Stop.
        for saved in readable {
            do {
                for var segment in try segments(saved.id) {
                    var changed = false
                    if segment.localRequestID != nil {
                        segment.localRequestID = nil
                        if segment.validLocalChinese == nil && segment.localError == nil { segment.localAttemptedRevision = nil }
                        changed = true
                    }
                    if segment.status == .pending && segment.gptRequestID != nil {
                        segment.gptRequestID = nil; segment.submittedAt = nil; segment.chinese = nil; changed = true
                    }
                    if changed { try append(segment, session: saved.id) }
                }
            } catch {
                damagedTranscripts.insert(saved.id)
                issues.append("课堂 \(saved.id) 翻译队列恢复不完整：\(error.localizedDescription)；原文件保留")
            }
        }
        let readableIDs = Set(readable.map(\.id))
        for directory in directories {
            if let id = UUID(uuidString: directory.lastPathComponent), !isDeleted(id), !readableIDs.contains(id) {
                issues.append("课堂 \(id) 的 metadata 无法读取；原文件保留，可从文件共享取回")
            }
        }
        for var session in readable where [.recording, .paused, .interrupted].contains(session.state) {
            guard !damagedTranscripts.contains(session.id) else { continue }
            do {
            session.state = .recovered
            // Include the current chunk even if the app died before its close event.
            let files = try FileManager.default.contentsOfDirectory(at: folder(session.id), includingPropertiesForKeys: nil)
            session.audioFiles = files.filter { $0.pathExtension == "caf" }.map(\.lastPathComponent).sorted()
            let savedSegments = try segments(session.id)
            let coverage = TranscriptCoverage(savedSegments)
            let lastEnd = savedSegments.map(\.end).max() ?? -1
            var lastOffset = max(session.duration, lastEnd)
            var lastActivityAt = session.stoppedAt ?? session.startedAt
            for name in ["audio-index.jsonl", "diagnostics.jsonl"] {
                try JSONLines.scan(Diagnostic.self, at: folder(session.id).appendingPathComponent(name)) {
                    if let offset = $0.offset, offset.isFinite { lastOffset = max(lastOffset, offset) }
                    if let captured = $0.fields["captured_seconds"].flatMap(Double.init) { session.updateRecordingDuration(captured) }
                    lastActivityAt = max(lastActivityAt, $0.at)
                }
            }
            var buffer = SentenceBuffer()
            try JSONLines.scan(SpeechPiece.self, at: folder(session.id).appendingPathComponent("speech-final.jsonl")) { piece in
                if piece.end.isFinite { lastOffset = max(lastOffset, piece.end) }
                lastActivityAt = max(lastActivityAt, piece.audioEndedAt ?? piece.receivedAt)
                if !coverage.contains(piece), let segment = buffer.append(piece) {
                    try append(segment, session: session.id)
                }
            }
            if let tail = buffer.flush() { try append(tail, session: session.id) }
            session.duration = max(max(0, lastOffset), session.usesRecordingTimeline ? session.recordingSeconds : 0)
            if session.usesRecordingTimeline { session.updateRecordingDuration(session.duration) }
            session.stoppedAt = session.usesRecordingTimeline ? lastActivityAt : session.startedAt.addingTimeInterval(session.duration)
            try save(session)
            try log(Diagnostic("process_recovery", fields: ["gap": "Recording ended when app/process terminated; audio files retained"]), session: session.id)
            } catch {
                issues.append("课堂 \(session.id) 恢复不完整：\(error.localizedDescription)；原文件保留")
            }
        }
        return issues
    }
    public func export(_ id: UUID, language: ExportLanguage, markdown: Bool, original: Bool = false) throws -> URL {
        guard let session = try sessions().first(where: { $0.id == id }) else { throw WLFailure.message("Session not found") }
        let directory = try exportDirectory(id)
        let url = directory.appendingPathComponent("WilliamLecture-\(language.rawValue)-\(UUID().uuidString).\(markdown ? "md" : "txt")")
        let records = try segments(id)
        let document = original ? nil : try content(id)
        var lines = ["\(markdown ? "# " : "")\(session.displayTitle)", "Session: \(session.id)", "Date: \(session.startedAt.ISO8601Format())", ""]
        if let document, document.state != .completed { lines.append("课后处理：\(document.state.label)。文件为当前快照，缺失内容明确标记。") }
        if !session.allowsAudioUse { lines.append("录音已清理；时间戳及已保存内容保留。") }
        if let document, document.audioRepairWarning != nil {
            lines.append(session.allowsAudioUse ? "部分音频尚未补转写；已保存的文字和译文可用，请核对音频与缺口记录。" : "部分内容未补转写，录音已清理，无法恢复缺失文字。")
        }
        lines.insert(session.usesRecordingTimeline ? "时间轴：实际录音，暂停不计时。" : "时间轴：旧版课堂，保留暂停空档。", at: 3)
        var gaps: [Diagnostic] = []
        try JSONLines.scan(Diagnostic.self, at: folder(id).appendingPathComponent("diagnostics.jsonl")) {
            if $0.fields["gap"] != nil { gaps.append($0) }
        }
        for record in records {
            let corrected = document?.correction(for: record)
            lines.append("[\(Self.timestamp(record.start)) – \(Self.timestamp(record.end))]")
            if language != .chinese { lines.append(corrected?.english ?? record.english) }
            if language != .english {
                if let corrected, !corrected.chinese.isEmpty { lines.append(corrected.chinese) }
                else if record.finalChinese != nil { lines.append(record.finalChinese!) }
                else if let local = record.validLocalChinese { lines.append("[本机翻译 / GPT 未完成] \(local)") }
                else if record.status == .mock { lines.append("[MOCK / 模拟翻译，非真实中文] \(record.chinese ?? "")") }
                else { lines.append("[中文缺失：\(record.status.rawValue)]") }
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
        let directory = try exportDirectory(id)
        let target = directory.appendingPathComponent("diagnostics-\(UUID().uuidString).jsonl")
        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: target) }
        else { try Data().write(to: target, options: .atomic) }
        return target
    }
    public func audioOffsets(_ id: UUID) throws -> [String: Double] {
        guard try sessionMetadata(id).allowsAudioUse else { return [:] }
        var offsets: [String: Double] = [:]
        try JSONLines.scan(Diagnostic.self, at: folder(id).appendingPathComponent("audio-index.jsonl")) {
            if ["audio_chunk_open", "audio_chunk_first_frame"].contains($0.event), let name = $0.fields["file"],
               name == URL(fileURLWithPath: name).lastPathComponent,
               let offset = $0.offset, offset.isFinite { offsets[name] = max(0, offset) }
        }
        for name in offsets.keys where !FileManager.default.fileExists(atPath: folder(id).appendingPathComponent(name).path) {
            throw WLFailure.message("音频片段缺失：\(name)；无法生成完整 M4A，现存 CAF 保留")
        }
        return offsets
    }
    func discardIndexes(for id: UUID) {
        if pendingSession == id { pendingSession = nil; pendingIndex = [:] }
        if translationSession == id { translationSession = nil; translationIndex = [:] }
    }
    public nonisolated static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds)); return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
    public nonisolated static func readingTime(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        return total < 3600 ? String(format: "%02d:%02d", total / 60, total % 60)
            : String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
