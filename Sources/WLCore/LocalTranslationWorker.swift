import Foundation

public typealias LocalTranslationOperation = @Sendable (String) async throws -> String
public enum LocalProviderFailure: Error, LocalizedError, Sendable, Equatable {
    case unavailable, busy
    public var errorDescription: String? {
        self == .unavailable ? "英文/简体中文模型未准备，请在设置中准备" : "上一项本机翻译尚未结束"
    }
}

/// One real operation at a time. A deadline invalidates callbacks but never pretends
/// an uncooperative operation has finished or opens a second slot beside it.
@MainActor public final class LocalTranslationWorker {
    public var onDraft: ((DraftTranslationRequest, String, Date) -> DraftAcceptance)?
    public var onUpdate: ((TranscriptSegment) -> Void)?
    public var onState: ((String) -> Void)?
    private let store: SessionStore
    private let session: UUID
    private let operation: LocalTranslationOperation
    private let cancelOperation: @Sendable () async -> Void
    private let deadlineSeconds: Double
    private let draftDelay: Double
    private let draftInterval: Double
    private let mock: Bool
    private var running: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var draftTimer: Task<Void, Never>?
    private var diagnosticWrites: Task<Void, Never>?
    private var activeID: UUID?
    private var activeStable: TranscriptSegment?
    private var pendingDraft: DraftTranslationRequest?
    private var draftReadyAt: Date?
    private var lastDraftAt = Date.distantPast
    private var lastDraft: DraftTranslationRequest?
    private var wantsDraft = true
    private var newestStable = true
    private var foreground = true
    private var disabled = false
    private var stopped = false
    private var retryWake: Task<Void, Never>?
    private var recovering = false
    private var wakeRequested = false
    public var resourceCounts: (running: Int, pendingDraft: Int) { (running == nil ? 0 : 1, pendingDraft == nil ? 0 : 1) }

    public init(store: SessionStore, session: UUID, deadlineSeconds: Double = 4, draftDelay: Double = 0.3,
                draftInterval: Double = 0.5, mock: Bool = false, operation: @escaping LocalTranslationOperation,
                cancelOperation: @escaping @Sendable () async -> Void = {}) {
        self.store = store; self.session = session; self.deadlineSeconds = max(0.001, deadlineSeconds)
        self.draftDelay = max(0, draftDelay); self.draftInterval = max(0, draftInterval)
        self.operation = operation; self.cancelOperation = cancelOperation; self.mock = mock
    }
    public func offer(_ request: DraftTranslationRequest) {
        guard !disabled, request.sessionID == session else { return }
        if let lastDraft, lastDraft.captionID == request.captionID, lastDraft.epoch == request.epoch,
           lastDraft.revision == request.revision, lastDraft.english == request.english { return }
        pendingDraft = request
        if draftReadyAt == nil { draftReadyAt = max(Date().addingTimeInterval(draftDelay), lastDraftAt.addingTimeInterval(foreground ? draftInterval : max(1, draftInterval))) }
        // Do not reset this timer for every revision: continuous speech must not starve drafts.
        if draftTimer == nil, let ready = draftReadyAt {
            draftTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, ready.timeIntervalSinceNow))) } catch { return }
                self?.draftTimer = nil; self?.kick()
            }
        }
        kick()
    }
    public func clearDraft() { pendingDraft = nil; draftReadyAt = nil; draftTimer?.cancel(); draftTimer = nil }
    public func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        kick()
    }
    public func resumeAfterForeground() async {
        guard !stopped else { return }
        retryWake?.cancel(); retryWake = nil
        do {
            try await store.resetLocalFailures(session, excluding: Set(activeStable.map { [$0.id] } ?? []))
            guard !stopped else { return }
            disabled = false; lastDraft = nil; kick()
        } catch { if !stopped { onState?("本机翻译队列：\(error.localizedDescription)") } }
    }
    private func scheduleRecovery() {
        guard !stopped, retryWake == nil else { return }
        retryWake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !stopped else { return }
            retryWake = nil; await resumeAfterForeground()
        }
    }
    public func kick() {
        guard !disabled else { return }
        if pump != nil { wakeRequested = true; return }
        guard running == nil, !recovering else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            do {
                let stable = try await store.localPending(session, newestFirst: newestStable)
                guard !disabled, !Task.isCancelled, running == nil, !recovering else { pump = nil; return }
                let readyDraft = pendingDraft != nil && (draftReadyAt?.timeIntervalSinceNow ?? 1) <= 0
                if readyDraft && (wantsDraft || stable == nil), let draft = pendingDraft {
                    clearDraft(); lastDraft = draft; lastDraftAt = Date(); wantsDraft = false
                    start(draft: draft, stable: nil, request: UUID())
                } else if let stable {
                    let request = UUID()
                    if let begun = try await store.beginLocal(stable, session: session, request: request) {
                        if disabled || Task.isCancelled { try? await store.cancelLocal(begun, session: session, request: request) }
                        else { wantsDraft = true; newestStable.toggle(); start(draft: nil, stable: begun, request: request) }
                    }
                }
            } catch { disabled = true; onState?("本机翻译不可用：\(error.localizedDescription)；其他链路继续") }
            pump = nil
            if wakeRequested { wakeRequested = false; kick() }
        }
    }
    private func start(draft: DraftTranslationRequest?, stable: TranscriptSegment?, request: UUID) {
        activeID = request; activeStable = stable
        let english = draft?.english ?? stable!.english
        let startedAt = Date()
        let id = draft?.captionID ?? stable!.id
        let revision = draft?.revision ?? stable!.sourceRevision
        let offset = draft?.end ?? stable!.end
        let fields = ["segment": id.uuidString, "revision": "\(revision)", "request": request.uuidString, "draft": "\(draft != nil)", "mock": "\(mock)"]
        record(Diagnostic("local_translation_request", offset: offset, fields: fields, at: startedAt))
        running = Task { [weak self] in
            guard let self else { return }
            do {
                let contextSource = stable ?? TranscriptSegment(start: draft!.start, end: draft!.end, english: english)
                let context = (try? await store.englishContext(contextSource, session: session)) ?? ""
                let text = try await translate(english, context: context)
                let at = Date()
                guard !disabled, !Task.isCancelled, activeID == request else { finish(request); return }
                timeout?.cancel()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WLFailure.message("本机翻译返回空内容") }
                var resultFields = fields
                resultFields["request_ms"] = "\(Int(max(0, at.timeIntervalSince(startedAt)) * 1000))"
                if let draft {
                    let accepted = onDraft?(draft, text, at) ?? .stale
                    resultFields["acceptance"] = accepted.rawValue
                    resultFields["partial_to_result_ms"] = "\(Int(max(0, at.timeIntervalSince(draft.partialFirstAt)) * 1000))"
                    if accepted == .stale, let promoted = try await promoteFinalizedDraft(draft, text: text, request: request, at: at) {
                        resultFields["from_partial_request"] = "true"
                        onUpdate?(promoted)
                        record(Diagnostic("local_translation_completed", offset: promoted.end, fields: resultFields, at: at))
                    } else {
                        record(Diagnostic(accepted == .stale ? "local_stale_response" : "local_draft_result", offset: offset, fields: resultFields, at: at))
                    }
                } else if let stable {
                    if let merged = try await store.applyLocal(stable, session: session, request: request, chinese: text, at: at) {
                        onUpdate?(merged); record(Diagnostic("local_translation_completed", offset: offset, fields: resultFields, at: at))
                    } else { record(Diagnostic("local_stale_response", offset: offset, fields: resultFields, at: at)) }
                }
            } catch {
                if !disabled, !Task.isCancelled, activeID == request {
                    if let stable, let merged = try? await store.applyLocal(stable, session: session, request: request,
                        chinese: nil, at: Date(), error: error.localizedDescription) { onUpdate?(merged) }
                    // An ambiguous or empty fragment must not disable the provider for the lecture.
                    if let failure = error as? LocalProviderFailure {
                        if failure == .unavailable { disabled = true; clearDraft() }
                        scheduleRecovery()
                    }
                    onState?("本机翻译未完成：\(error.localizedDescription)；录音/GPT 继续")
                    var errorFields = fields; errorFields["error"] = error.localizedDescription
                    record(Diagnostic("local_translation_error", offset: offset, fields: errorFields))
                }
            }
            finish(request)
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.deadlineSeconds ?? 4)) } catch { return }
            guard let self, activeID == request, running != nil else { return }
            recovering = true; lastDraft = nil; running?.cancel()
            onState?("本机翻译超时；录音继续，正在恢复")
            record(Diagnostic("local_translation_timeout", offset: offset, fields: fields))
            if let stable, let merged = try? await store.applyLocal(stable, session: session, request: request,
                chinese: nil, at: Date(), error: "本机翻译超时") { onUpdate?(merged) }
            await cancelOperation()
            // running remains occupied until the underlying operation actually returns.
            recovering = false; timeout = nil; scheduleRecovery(); kick()
        }
    }
    private func translate(_ english: String, context: String) async throws -> String {
        if !mock, let draft = ShortUtterance.draft(english, context: context) { return draft }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let text = try await operation(english)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            if attempt == 0 { try await Task.sleep(for: .milliseconds(150)) }
        }
        throw WLFailure.message("本机翻译返回空内容")
    }
    private func promoteFinalizedDraft(_ draft: DraftTranslationRequest, text: String, request: UUID, at: Date) async throws -> TranscriptSegment? {
        // A final may arrive while the exact same partial request is in flight.
        // Reuse only a durable full-source match, never a prefix or a revoked revision.
        var source = TranscriptSegment(start: draft.start, end: draft.end, english: draft.english)
        source.id = draft.captionID; source.revision = draft.revision
        guard !disabled, !Task.isCancelled,
              let current = try await store.translationSnapshot(source, session: session),
              let begun = try await store.beginLocal(current, session: session, request: request) else { return nil }
        if disabled || Task.isCancelled { try? await store.cancelLocal(begun, session: session, request: request); return nil }
        return try await store.applyLocal(begun, session: session, request: request, chinese: text, at: at)
    }
    private func finish(_ request: UUID) {
        guard activeID == request else { return }
        if !recovering { timeout?.cancel(); timeout = nil }
        running = nil; activeID = nil; activeStable = nil
        kick()
    }
    public func shutdown() async {
        stopped = true; disabled = true; retryWake?.cancel(); retryWake = nil
        clearDraft(); pump?.cancel(); timeout?.cancel(); running?.cancel()
        if let source = activeStable, let request = activeID { try? await store.cancelLocal(source, session: session, request: request) }
        onDraft = nil; onUpdate = nil; onState = nil
        await cancelOperation()
    }
    public func flushDiagnostics() async { await diagnosticWrites?.value }
    private func record(_ diagnostic: Diagnostic) {
        let previous = diagnosticWrites
        diagnosticWrites = Task { await previous?.value; try? await store.log(diagnostic, session: session) }
    }
}
