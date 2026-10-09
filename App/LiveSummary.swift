import SwiftUI
import UIKit
import WLCore

/// User-triggered snapshot. Never joins or cancels the subtitle/recording queues.
@MainActor final class LiveSummary: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var error = ""
    @Published private(set) var loading = false
    @Published private(set) var offset = 0.0
    @Published private(set) var snapshot: StudySnapshot?
    @Published private(set) var sources: [StudySource] = []
    private(set) var sessionID: UUID?
    private var task: Task<Void, Never>?
    private var token = UUID()
    private let api = Translator() // Separate connection pool; live captions retain their slots.
    func cancel(clear: Bool = false) {
        token = UUID(); task?.cancel(); task = nil; loading = false
        if clear { text = ""; error = ""; offset = 0; snapshot = nil; sources = []; sessionID = nil }
    }
    func generate(session: LectureSession,
                  config: TranslatorConfiguration, store: SessionStore) {
        guard !loading else { return }
        cancel(clear: sessionID != session.id); let request = token
        loading = true; error = ""; sessionID = session.id
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await store.segments(session.id)
                try Task.checkCancellation()
                // Cite only persisted stable rows. A partial can be revised or revoked.
                let sources = rows.map { StudySource(id: $0.id, offset: $0.start, english: $0.displayEnglish) }
                guard !sources.isEmpty else { throw WLFailure.message("暂无已定稿内容") }
                let entry = UsageEntry(scope: .manualSummary, model: config.model)
                if !config.mock { try await store.reserveUsage(entry, session: session.id) }
                let result = try await api.summarize(sources, course: session.course, config: config,
                    usage: { metadata in try? await store.finishUsage(entry, metadata: metadata, session: session.id) })
                try Task.checkCancellation()
                guard token == request else { return }
                self.sources = sources; snapshot = result; offset = rows.map(\.end).max() ?? 0
                text = result.markdown(sources: sources); loading = false; task = nil
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
    var jump: ([UUID]) -> Void
    @State private var tab = 0
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if summary.snapshot != nil {
                        Text("截至 \(SessionStore.readingTime(summary.offset)) · 已定稿内容").font(.caption).foregroundStyle(.secondary)
                    }
                    if summary.loading { ProgressView("正在生成摘要").accessibilityIdentifier("live-summary-loading") }
                    else if !summary.error.isEmpty {
                        Text(summary.error).font(.subheadline).foregroundStyle(Color.williamWarning)
                        Button("重试", action: regenerate)
                    }
                    if let snapshot = summary.snapshot {
                        Picker("内容", selection: $tab) { Text("摘要").tag(0); Text("思维导图").tag(1) }.pickerStyle(.segmented)
                        if tab == 0 {
                            Text(snapshot.overview).textSelection(.enabled).lineSpacing(6).accessibilityIdentifier("live-summary-result")
                            StudyOutlineView(nodes: snapshot.outline, sources: summary.sources, jump: jump)
                        } else {
                            StudyMapView(title: snapshot.title, nodes: snapshot.outline, sources: summary.sources, jump: jump)
                        }
                    }
                }.frame(maxWidth: 720, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }.navigationTitle("当前摘要").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: regenerate) { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("刷新当前摘要").disabled(summary.loading)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { UIPasteboard.general.string = summary.text } label: { Image(systemName: "doc.on.doc") }
                            .accessibilityLabel("复制摘要").disabled(summary.text.isEmpty)
                    }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
