import Foundation

public struct StudyGeneration: Codable, Sendable {
    public var requestID: UUID
    public var state: LessonProcessingState
    public var snapshot: String
    public var missingRevisions: Int
    public var error: String?
    public var updatedAt: Date
    public init(snapshot: String, missing: Int) {
        requestID = UUID(); state = .pending; self.snapshot = snapshot
        missingRevisions = missing; updatedAt = Date()
    }
}

extension LessonContent {
    public func effectiveFingerprint(_ sources: [TranscriptSegment]) -> String {
        var effective = sources
        for i in effective.indices {
            effective[i].english = correction(for: sources[i])?.english ?? sources[i].displayEnglish
            effective[i].english += "\n" + (correction(for: sources[i])?.chinese ?? sources[i].exportChinese ?? "")
        }
        return Self.fingerprint(effective)
    }
    public func hasOutdatedStudy(_ sources: [TranscriptSegment]) -> Bool {
        guard !outline.isEmpty, let fingerprint = study?.snapshot else { return false }
        return fingerprint != effectiveFingerprint(sources)
    }
}

extension SessionStore {
    public func beginStudy(_ id: UUID) throws -> (LessonContent, [TranscriptSegment], UUID) {
        let rows = try segments(id)
        guard !rows.isEmpty else { throw WLFailure.message("暂无可生成内容") }
        var content = try self.content(id) ?? LessonContent(sessionID: id, segments: rows)
        if content.fingerprint != LessonContent.fingerprint(rows) {
            let previous = content
            content = LessonContent(sessionID: id, segments: rows)
            content.corrected = rows.compactMap { previous.correction(for: $0) }
            content.title = previous.title; content.overview = previous.overview; content.outline = previous.outline
            content.processingVersion = previous.processingVersion
        }
        // A manual study request must not implicitly enqueue automatic revision.
        if content.processingVersion == nil { content.state = .completed }
        content.processingVersion = 119
        var study = StudyGeneration(snapshot: content.effectiveFingerprint(rows), missing: rows.filter { content.correction(for: $0) == nil }.count)
        study.state = .generating; content.study = study; content.updatedAt = Date()
        guard try saveContent(content) else { throw WLFailure.message("课堂内容已更新，请重试") }
        return (content, rows, study.requestID)
    }
    @discardableResult public func finishStudy(_ id: UUID, request: UUID, title: String? = nil, overview: String? = nil,
                                               outline: [StudyNode]? = nil, state: LessonProcessingState, error: String? = nil) throws -> Bool {
        guard var content = try self.content(id), var study = content.study, study.requestID == request else { return false }
        let rows = try segments(id)
        if content.fingerprint != LessonContent.fingerprint(rows) {
            let previous = content
            content = LessonContent(sessionID: id, segments: rows)
            content.corrected = rows.compactMap { previous.correction(for: $0) }
            content.title = previous.title; content.overview = previous.overview; content.outline = previous.outline
            content.processingVersion = previous.processingVersion; content.state = previous.state
        }
        study.state = state; study.error = error; study.updatedAt = Date(); content.study = study
        if let title, let overview, let outline { content.title = title; content.overview = overview; content.outline = outline }
        content.updatedAt = Date()
        return try saveContent(content)
    }
}
