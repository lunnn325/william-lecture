import SwiftUI
import UIKit
import WLCore

@MainActor final class ConversationController: ObservableObject {
    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    private(set) var sessionID: UUID?
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var store: SessionStore?
    private var current: ConversationMessage?
    private var lease: UIBackgroundTaskIdentifier = .invalid
    private var lastPersist = Date.distantPast
    private let api = Translator(timeout: 300)

    func attach(_ id: UUID, store: SessionStore) async {
        if sessionID == id, loading { return }
        if sessionID != id { cancel(); sessionID = id; messages = []; error = "" }
        self.store = store
        let owner = token
        do {
            let saved = try await store.recoverConversation(id)
            guard sessionID == id, token == owner else { return }
            messages = saved
        } catch { if sessionID == id { self.error = error.localizedDescription } }
    }
    func send(_ question: String, retry: UUID? = nil, config: TranslatorConfiguration) {
        guard !loading, let id = sessionID, let store else { return }
        loading = true; error = ""; token = UUID(); let owner = token
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let turn = try await store.beginConversation(id, question: question, retry: retry)
                guard !Task.isCancelled, sessionID == id, token == owner else {
                    _ = try? await store.updateConversation(id, message: turn.message.id, request: turn.message.requestID!, text: "", state: "interrupted")
                    return
                }
                current = turn.message; messages = try await store.conversation(id)
                let entry = UsageEntry(scope: .conversation, model: config.model)
                if !config.mock { try await store.reserveUsage(entry, session: id) }
                let answer = try await api.converse(turn.input, config: config,
                    usage: { metadata in try? await store.finishUsage(entry, metadata: metadata, session: id) },
                    reset: { [weak self] in await self?.receive("", owner: owner, reset: true) },
                    delta: { [weak self] part in await self?.receive(part, owner: owner) })
                try Task.checkCancellation()
                guard token == owner, sessionID == id, let current else { return }
                guard try await store.updateConversation(id, message: current.id, request: current.requestID!, text: answer, state: "completed") else { return }
                messages = try await store.conversation(id)
                try? await store.log(Diagnostic("conversation_completed", fields: ["message": current.id.uuidString, "reasoning": "medium"]), session: id)
            } catch {
                guard token == owner, sessionID == id else { return }
                self.error = DiagnosticRedaction.redact(error.localizedDescription)
                try? await store.log(Diagnostic("conversation_error", fields: ["error": self.error, "reasoning": "medium"]), session: id)
                if let current {
                    let text = current.text, request = current.requestID!
                    _ = try? await store.updateConversation(id, message: current.id, request: request, text: text, state: "failed", error: self.error)
                    messages = (try? await store.conversation(id)) ?? messages
                }
            }
            if token == owner { loading = false; task = nil; current = nil; endLease() }
        }
    }
    private func receive(_ part: String, owner: UUID, reset: Bool = false) async {
        guard owner == token, var message = current, let id = sessionID, let store else { return }
        message.text = reset ? "" : message.text + part; current = message
        if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i] = message }
        if Date().timeIntervalSince(lastPersist) > 0.5 || reset {
            lastPersist = Date()
            _ = try? await store.updateConversation(id, message: message.id, request: message.requestID!, text: message.text, state: "pending")
        }
    }
    func cancel(session: UUID? = nil) {
        if let session, sessionID != session { return }
        token = UUID(); task?.cancel(); task = nil; loading = false; endLease()
        if let message = current, let id = sessionID, let store, let request = message.requestID {
            Task { _ = try? await store.updateConversation(id, message: message.id, request: request, text: message.text,
                                                         state: "interrupted", error: "生成已停止，可重试") }
            if let i = messages.firstIndex(where: { $0.id == message.id }) {
                messages[i].state = "interrupted"; messages[i].error = "生成已停止，可重试"
            }
        }
        current = nil
    }
    func foreground(_ value: Bool) {
        if value { endLease() }
        else if loading, lease == .invalid {
            lease = UIApplication.shared.beginBackgroundTask(withName: "WL.conversation") { [weak self] in
                Task { @MainActor in self?.cancel() }
            }
        }
    }
    private func endLease() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
    }
}

struct LectureConversationView: View {
    @ObservedObject var conversation: ConversationController
    let config: TranslatorConfiguration
    let jump: ([UUID]) -> Void
    @State private var question = ""
    @State private var following = true
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if conversation.messages.isEmpty { Text("暂无对话").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(conversation.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.role == "user" ? "问题" : "回答").font(.caption).foregroundStyle(.secondary)
                            if !message.text.isEmpty {
                                Text(.init(message.text)).textSelection(.enabled).lineSpacing(6)
                                    .accessibilityIdentifier("conversation-text-\(message.role)")
                                    .environment(\.openURL, OpenURLAction { url in
                                        guard url.scheme == "wl-source", let alias = url.host,
                                              let source = message.sources?.first(where: { $0.alias == alias }) else { return .discarded }
                                        jump([source.id]); return .handled
                                    })
                            }
                            if message.state == "pending" { ProgressView("正在回答") }
                            if let error = message.error { Text(error).font(.footnote).foregroundStyle(Color.williamWarning) }
                            HStack {
                                if !message.text.isEmpty {
                                    Button { UIPasteboard.general.string = message.text } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44) }.accessibilityLabel("复制回答")
                                }
                                if message.role == "assistant", ["failed", "interrupted"].contains(message.state) {
                                    Button("重试") { following = true; conversation.send(message.question ?? "", retry: message.id, config: config) }.disabled(conversation.loading)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }.frame(maxWidth: 720, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }.onScrollPhaseChange { _, phase in if phase == .interacting { following = false } }
                .onChange(of: conversation.messages) { _, _ in if following { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if !conversation.error.isEmpty { Text(conversation.error).font(.footnote).foregroundStyle(Color.williamWarning) }
                        HStack(alignment: .bottom) {
                            TextField("询问课堂内容或其他问题", text: $question, axis: .vertical).lineLimit(1...5)
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("conversation-input")
                            if conversation.loading {
                                Button { conversation.cancel() } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }.accessibilityLabel("停止回答")
                            } else {
                                Button { let value = question; question = ""; following = true; conversation.send(value, config: config) } label: {
                                    Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 44, height: 44)
                                }.disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送问题")
                            }
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
                }
        }
    }
}
