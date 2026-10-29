import Foundation
import Combine
import UIKit
import WLCore

/// A separate durable queue: post-class work can never own the microphone lifecycle.
@MainActor final class LessonProcessingCoordinator: ObservableObject {
    @Published private(set) var change = 0
    @Published private(set) var enqueueFailures: [UUID: String] = [:]
    private let store: SessionStore
    private let api = LessonAPI()
    private var task: Task<Void, Never>?
    private var studies: [UUID: Task<Void, Never>] = [:]
    private var recording = false
    private var foreground = true
    private var online = true
    private var lease: UIBackgroundTaskIdentifier = .invalid
    private var deferredWake = false
    private var heldSessions: Set<UUID> = []
    private var currentSession: UUID?
    init(store: SessionStore) { self.store = store }
    func setRecording(_ value: Bool) { recording = value; if value { task?.cancel(); for job in studies.values { job.cancel() } } else { wake() } }
    func setForeground(_ value: Bool) {
        foreground = value
        if value { endLease(); wake() }
        else if task != nil || !studies.isEmpty { beginLease() }
    }
    func setOnline(_ value: Bool) { online = value; if value { wake() } }
    func configurationChanged() async {
        guard Keychain.load() != nil else { return }
        for session in (try? await store.sessions()) ?? [] {
            if let content = try? await store.content(session.id), content.processingVersion == 119, content.state == .needsConfiguration {
                await enqueue(session, retry: true)
            }
        }
        wake()
    }
    func speechModelsPrepared() async {
        for session in (try? await store.sessions()) ?? [] where [.stopped, .recovered].contains(session.state) {
            guard session.allowsAudioUse else { continue }
            guard let content = try? await store.content(session.id), content.processingVersion == 119 else { continue }
            if content.audioRepairWarning != nil || (content.state == .failed && content.error?.contains("Speech") == true) {
                await enqueue(session, retry: true)
            }
        }
        wake()
    }
    /// Resume only an already-requested legacy job, never submit untouched history.
    func recoverKnownProcessingFailures() async {
        // Versioned new work may resume; legacy failures require a deliberate Retry.
        for session in (try? await store.sessions()) ?? [] {
            if let content = try? await store.content(session.id), content.processingVersion == 119,
               content.study?.state == .pending || content.study?.state == .generating {
                generateStudy(session)
            }
        }
        wake()
    }
    func beginLease() {
        guard lease == .invalid else { return }
        lease = UIApplication.shared.beginBackgroundTask(withName: "WL.save-and-process") { [weak self] in
            Task { @MainActor in self?.task?.cancel(); self?.studies.values.forEach { $0.cancel() }; self?.endLease() }
        }
    }
    private func endLease() { if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid } }
    func enqueue(_ session: LectureSession, retry: Bool = false) async {
        guard !heldSessions.contains(session.id) else { return }
        do {
            let sources = try await store.segments(session.id)
            var content = try await store.content(session.id) ?? LessonContent(sessionID: session.id, segments: sources)
            if content.fingerprint != LessonContent.fingerprint(sources) { content = LessonContent(sessionID: session.id, segments: sources) }
            content.processingVersion = 119
            if content.state != .completed || retry { content.state = .pending; content.error = nil; _ = try await store.saveContent(content) }
            enqueueFailures.removeValue(forKey: session.id)
            change += 1; wake()
        } catch {
            enqueueFailures[session.id] = DiagnosticRedaction.redact(error.localizedDescription)
            change += 1
        }
    }
    func wake() {
        guard !recording, online, foreground || lease != .invalid else { return }
        guard task == nil else { deferredWake = true; return }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil; self.currentSession = nil; if self.studies.isEmpty { self.endLease() }
                if self.deferredWake { self.deferredWake = false; self.wake() }
            }
            do {
                let sessions = try await store.sessions()
                for session in sessions where [.stopped, .recovered].contains(session.state) {
                    try Task.checkCancellation()
                    guard !heldSessions.contains(session.id), (try? await store.sessionMetadata(session.id)) != nil else { continue }
                    if let saved = try await store.content(session.id), saved.processingVersion == 119,
                       saved.study?.state == .pending || saved.study?.state == .generating { generateStudy(session) }
                    currentSession = session.id
                    guard !heldSessions.contains(session.id) else { currentSession = nil; continue }
                    // Old sessions are not silently migrated or sent to a new model.
                    guard let content = try await store.content(session.id), content.processingVersion == 119, content.state.automatic, !Task.isCancelled,
                          !heldSessions.contains(session.id) else { currentSession = nil; continue }
                    await process(session, initial: content)
                    currentSession = nil
                }
            } catch { }
        }
    }
    /// Hold only the target classroom. A queue snapshot cannot restart it during cleanup.
    func holdSession(_ id: UUID) async {
        heldSessions.insert(id)
        if let study = studies[id] { study.cancel(); await study.value }
        if currentSession == id { task?.cancel(); await task?.value }
        enqueueFailures.removeValue(forKey: id)
    }
    func releaseSession(_ id: UUID) { heldSessions.remove(id); change += 1; wake() }
    private func save(_ content: inout LessonContent) async throws {
        content.updatedAt = Date()
        guard try await store.saveContent(content) else { throw LessonAPIError.invalid("原文已更新，旧处理结果已丢弃") }
        change += 1
    }
    private func process(_ session: LectureSession, initial: LessonContent) async {
        var document = initial
        do {
            let currentSources = try await store.segments(session.id)
            if document.fingerprint != LessonContent.fingerprint(currentSources) {
                document = LessonContent(sessionID: session.id, segments: currentSources)
            }
            document.processingVersion = 119; document.state = .repairing; document.error = nil; try await save(&document)
            var repairWarning: String?
            do { try await SpeechAudioRepair.repair(session, store: store) }
            catch is CancellationError { throw CancellationError() }
            catch {
                repairWarning = DiagnosticRedaction.redact(error.localizedDescription)
                try? await store.log(Diagnostic("audio_repair_deferred", fields: ["error": repairWarning ?? ""]), session: session.id)
            }
            let sources = try await store.segments(session.id)
            if document.fingerprint != LessonContent.fingerprint(sources) {
                document = LessonContent(sessionID: session.id, segments: sources)
                document.processingVersion = 119
                try await save(&document)
            }
            document.audioRepairWarning = repairWarning
            if !(try await store.sessionMetadata(session.id)).allowsAudioUse {
                document.audioRepairWarning = try await store.audioRepairRanges(session.id).isEmpty ? nil : "录音已清理，未补转写的内容无法恢复"
            }
            guard !sources.isEmpty else { throw LessonAPIError.invalid(session.allowsAudioUse ? "未识别到内容，录音可回放和导出" : "没有可处理的文字，录音已清理") }
            guard let key = Keychain.load(), !key.isEmpty else {
                document.state = .needsConfiguration; document.error = "未配置 OpenAI Key"; try await save(&document); return
            }
            document.state = .revising; document.revisionPendingIDs = []; try await save(&document)
            var position = 0
            while position < sources.count {
                try Task.checkCancellation()
                let first = sources[position]
                var end = position + 1
                while end < sources.count && sources[end].end - first.start <= 120 && end - position < 80 { end += 1 }
                let chunk = Array(sources[position..<end])
                if !chunk.allSatisfy({ document.correction(for: $0) != nil }) {
                    let targetIDs = Set(chunk.map(\.id))
                    let surrounding = sources.filter { $0.end >= first.start - 30 && $0.start <= chunk.last!.end + 30 && !targetIDs.contains($0.id) }
                    let corrections: [CorrectedSegment]
                    do {
                        corrections = try await api.revise(chunk, surrounding: surrounding, course: session.course, key: key, store: store, session: session.id)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if error is URLError || error is APIError { throw error }
                        document.revisionPendingIDs = (document.revisionPendingIDs ?? []) + chunk.map(\.id)
                        try? await store.log(Diagnostic("post_revision_chunk_failed", fields: ["error": error.localizedDescription]), session: session.id)
                        position = end; try await save(&document); continue
                    }
                    let accepted = Set(corrections.map(\.id))
                    document.revisionPendingIDs = (document.revisionPendingIDs ?? []) + chunk.filter { !accepted.contains($0.id) }.map(\.id)
                    try Task.checkCancellation()
                    guard document.fingerprint == LessonContent.fingerprint(try await store.segments(session.id)) else {
                        throw LessonAPIError.invalid("原文已更新，旧修订已丢弃")
                    }
                    let ids = Set(corrections.map(\.id)); document.corrected.removeAll { ids.contains($0.id) }; document.corrected += corrections
                    // Persist the revision before making its translation available as fallback.
                    try await save(&document)
                }
                for source in chunk {
                    if let corrected = document.correction(for: source), !corrected.chinese.isEmpty {
                        try await store.repairTranslation(source, chinese: corrected.chinese, session: session.id)
                    }
                }
                position = end
            }
            let missing = sources.filter { document.correction(for: $0) == nil }.map(\.id)
            document.revisionPendingIDs = missing
            document.state = missing.isEmpty ? .completed : .failed
            document.error = missing.isEmpty ? nil : "\(missing.count) 段尚未完成修订，已保留现有文字，可重试"
            try await save(&document)
            try await store.log(Diagnostic("lesson_processing_complete", fields: ["segments": "\(sources.count)", "fingerprint": document.fingerprint]), session: session.id)
            change += 1
        } catch is CancellationError {
            // The last durable progress record is automatically resumable. This write uses
            // a fresh task because the cancelled worker cannot commit new document results.
            document.state = .pending
            let snapshot = document
            Task { _ = try? await store.saveContent(snapshot); change += 1 }
        } catch {
            // Replay can persist valid segments before a later Speech error. Rebase the
            // status snapshot so that a failure remains visible and can be retried.
            if let currentSources = try? await store.segments(session.id),
               document.fingerprint != LessonContent.fingerprint(currentSources) {
                let previous = document
                document = LessonContent(sessionID: session.id, segments: currentSources)
                document.corrected = currentSources.compactMap { previous.correction(for: $0) }
                document.audioRepairWarning = previous.audioRepairWarning
            }
            document.processingVersion = 119
            if let e = error as? LessonAPIError, case .budget = e { document.state = .limitReached }
            else if error is URLError || (error as? APIError)?.retryable == true { document.state = .waitingForNetwork }
            else if let e = error as? APIError, [400, 401, 403, 404].contains(e.status) { document.state = .needsConfiguration }
            else { document.state = .failed }
            document.error = DiagnosticRedaction.redact(error.localizedDescription)
            try? await save(&document)
            try? await store.log(Diagnostic("lesson_processing_error", fields: ["state": document.state.rawValue, "error": document.error ?? ""]), session: session.id)
        }
    }
    func generateStudy(_ session: LectureSession, mock: Bool = false) {
        guard studies[session.id] == nil, !heldSessions.contains(session.id), !recording else { return }
        studies[session.id] = Task { [weak self] in
            guard let self else { return }
            defer { studies[session.id] = nil; if task == nil && studies.isEmpty { endLease() }; if Task.isCancelled && !recording && foreground { wake() } }
            var token: UUID?
            do {
                let (snapshot, sources, request) = try await store.beginStudy(session.id)
                token = request; change += 1
                let title: String, overview: String, outline: [StudyNode]
                if mock {
                    title = snapshot.title ?? "[MOCK] 课堂总结"
                    overview = "[MOCK] 模拟器生成结果。"
                    outline = snapshot.outline.isEmpty ? [StudyNode(id: "sample", title: "[MOCK] 课堂内容", body: "生成流程样例", segmentIDs: sources.prefix(1).map(\.id))] : snapshot.outline
                } else {
                    guard let key = Keychain.load(), !key.isEmpty else { throw WLFailure.message("未配置 OpenAI Key") }
                    (title, overview, outline) = try await api.study(sources, content: snapshot, course: session.course, key: key, store: store)
                }
                try Task.checkCancellation()
                guard try await store.finishStudy(session.id, request: request, title: title, overview: overview, outline: outline, state: .completed) else { return }
                try await store.updateLibraryFields(session.id, preview: overview)
            } catch {
                if let token {
                    let cancelled = error is CancellationError || Task.isCancelled
                    let state: LessonProcessingState = cancelled ? .pending : .failed
                    let message = DiagnosticRedaction.redact(error.localizedDescription)
                    // Cancellation cannot commit through a cancelled Task.
                    let store = self.store
                    await Task { try? await store.finishStudy(session.id, request: token, state: state, error: cancelled ? "生成已中断，等待恢复" : message) }.value
                } else { enqueueFailures[session.id] = error.localizedDescription }
            }
            change += 1
        }
        if !foreground { beginLease() }
    }

}
