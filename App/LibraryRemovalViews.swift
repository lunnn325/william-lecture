import SwiftUI
import WLCore

struct LibraryRemovalRequest {
    let session: LectureSession
    let audioOnly: Bool
    let incomplete: Bool
    var action: String { audioOnly ? "清理录音" : "删除记录" }
    var title: String { "\(action) · \(session.displayTitle)" }
    var message: String {
        if !audioOnly { return "永久删除这节课堂的录音、文字、笔记、摘要及 App 内导出文件，无法恢复。已保存到其他位置的副本保留。" }
        return "删除原始录音和 App 内的 M4A，保留文字、笔记、摘要和时间戳。已保存到其他位置的副本保留。"
            + (incomplete ? "\n尚未补转写的内容将无法恢复。已有文字的处理可继续。" : "")
    }
    static func prepare(_ session: LectureSession, audioOnly: Bool, store: SessionStore) async -> Self {
        let current = (try? await store.sessionMetadata(session.id)) ?? session
        let content = try? await store.content(session.id)
        let gaps = (try? await store.audioRepairRanges(session.id)) ?? []
        let segments = (try? await store.segments(session.id)) ?? []
        let incomplete = content?.state != .completed || !gaps.isEmpty || segments.contains { $0.exportChinese == nil }
        return Self(session: current, audioOnly: audioOnly, incomplete: incomplete)
    }
}

/// Shared confirmation and retry behavior for a card and an open classroom detail.
struct LibraryRemovalConfirmation: ViewModifier {
    @EnvironmentObject private var controller: LectureController
    @Binding var request: LibraryRemovalRequest?
    var beforeAction: @MainActor () -> Void = {}
    var onSuccess: @MainActor (Bool) async -> Void = { _ in }
    @State private var failure = ""
    @State private var retry: LibraryRemovalRequest?
    func body(content: Content) -> some View {
        content
            .overlay {
                if let retry, controller.libraryMutation == retry.session.id {
                    ProgressView(retry.audioOnly ? "正在清理录音" : "正在删除记录")
                        .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(failure.isEmpty ? request?.title ?? "课堂记录" : "操作未完成", isPresented: Binding(
                get: { request != nil || !failure.isEmpty }, set: { if !$0 { request = nil; failure = "" } })) {
                if !failure.isEmpty {
                    Button("关闭", role: .cancel) { failure = "" }
                    Button("重试") { if let retry { failure = ""; perform(retry) } }.disabled(!controller.libraryActionsAllowed)
                } else if let value = request {
                    Button("取消", role: .cancel) { request = nil }
                    Button(value.action, role: .destructive) { perform(value) }.disabled(!controller.libraryActionsAllowed)
                }
            } message: { Text(failure.isEmpty ? request?.message ?? "" : failure) }
    }
    private func perform(_ value: LibraryRemovalRequest) {
        request = nil; retry = value
        Task { @MainActor in
            guard controller.libraryActionsAllowed else { failure = "请先结束录课并等待保存或导出完成"; return }
            beforeAction()
            do {
                try await controller.removeLibraryFiles(value.session, audioOnly: value.audioOnly)
                retry = nil; await onSuccess(value.audioOnly)
            } catch { failure = error.localizedDescription }
        }
    }
}
