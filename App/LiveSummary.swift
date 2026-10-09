import SwiftUI
import UIKit
import WLCore

/// User-triggered snapshot. Never joins or cancels the subtitle/recording queues.
@MainActor final class LiveSummary: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var error = ""
    @Published private(set) var loading = false
    @Published private(set) var offset = 0.0
    private var task: Task<Void, Never>?
    private var token = UUID()
    private let api = Translator() // Separate connection pool; live captions retain their slots.
    func cancel(clear: Bool = false) {
        token = UUID(); task?.cancel(); task = nil; loading = false
        if clear { text = ""; error = ""; offset = 0 }
    }
    func generate(session: LectureSession, draft: WorkspaceCaption?, elapsed: Double,
                  config: TranslatorConfiguration, store: SessionStore) {
        guard !loading else { return }
        cancel(clear: true); let request = token
        loading = true; offset = elapsed
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await store.segments(session.id)
                try Task.checkCancellation()
                var lines = rows.map { "[\(SessionStore.readingTime($0.start))] \($0.displayEnglish)" }
                if let draft, draft.provisional, !rows.contains(where: { $0.id == draft.id }) {
                    lines.append("[\(SessionStore.readingTime(draft.start))，未定稿] \(draft.english)")
                }
                guard !lines.isEmpty else { throw WLFailure.message("暂无可总结内容") }
                let entry = UsageEntry(scope: .manualSummary, model: config.model)
                if !config.mock { try await store.reserveUsage(entry, session: session.id) }
                let result = try await api.summarize(lines.joined(separator: "\n"), course: session.course, config: config,
                    usage: { metadata in try? await store.finishUsage(entry, metadata: metadata, session: session.id) })
                try Task.checkCancellation()
                guard token == request else { return }
                text = result; loading = false; task = nil
            } catch {
                guard token == request else { return }
                loading = false; task = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
}

struct LiveSummaryView: View {
    @ObservedObject var summary: LiveSummary
    @Environment(\.dismiss) private var dismiss
    var regenerate: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("截至 \(SessionStore.readingTime(summary.offset))").font(.caption).foregroundStyle(.secondary)
                    if summary.loading { ProgressView("正在生成摘要").accessibilityIdentifier("live-summary-loading") }
                    else if !summary.error.isEmpty {
                        Text(summary.error).font(.subheadline).foregroundStyle(Color.williamWarning)
                        Button("重试", action: regenerate)
                    }
                    if !summary.text.isEmpty { Text(summary.text).textSelection(.enabled).lineSpacing(6).accessibilityIdentifier("live-summary-result") }
                }.frame(maxWidth: 720, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }.navigationTitle("当前摘要").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { UIPasteboard.general.string = summary.text } label: { Image(systemName: "doc.on.doc") }
                            .accessibilityLabel("复制摘要").disabled(summary.text.isEmpty)
                    }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
