import AVFoundation
import SwiftUI
import UIKit
import WLCore

/// A separate, ephemeral reader tool. It never writes transcript or note fields.
@MainActor final class WordLookupCoordinator: NSObject, ObservableObject, UIAdaptivePresentationControllerDelegate {
    enum Action: String { case dictionary = "词典", pronunciation = "发音", translation = "翻译", explanation = "解释" }
    @Published private(set) var selection: LookupSelection?
    @Published private(set) var focusedCaption: UUID?
    @Published private(set) var frozenEnglish = ""
    @Published private(set) var message = ""
    @Published private(set) var result = ""
    @Published private(set) var loading = false
    @Published private(set) var action: Action = .translation
    private(set) var owner: UUID?
    var editMenuVisible = false
    var isInteracting: Bool { owner != nil }
    private let store: SessionStore
    private let configuration: () -> TranslatorConfiguration
    private let recordingState: () -> SessionState?
    private let busy: () -> Bool
    private let course: () -> String
    private let mock: () -> Bool
    private let translator = Translator.shared
    private let local = AppleLocalTranslator() // Never cancel the subtitle translator.
    private let synthesizer = AVSpeechSynthesizer()
    private var speechState = LookupSpeechState()
    private var ownsSpeechAudio = false
    private var gate = LookupRequestGate()
    private var request: Task<Void, Never>?
    private var localTask: Task<String, Error>?
    private var localID = UUID()
    private var localCancellation: Task<Void, Never>?
    private var revision = 0
    private var selectedCourse = ""
    private var sessionID: UUID?
    private weak var textView: UITextView?
    private weak var presented: UIViewController?
    private var anchor = CGRect.zero
    private var beforePronunciation: (() -> Void)?

    init(store: SessionStore, configuration: @escaping () -> TranslatorConfiguration,
         recordingState: @escaping () -> SessionState?, busy: @escaping () -> Bool,
         course: @escaping () -> String, mock: @escaping () -> Bool) {
        self.store = store; self.configuration = configuration; self.recordingState = recordingState
        self.busy = busy; self.course = course; self.mock = mock
        super.init()
    }
    func focus(owner: UUID, session: UUID, caption: UUID, source: String, revision: Int, course: String,
               view: UITextView, beforePronunciation: (() -> Void)?) {
        if self.owner == owner && focusedCaption == caption { return }
        close()
        self.owner = owner; sessionID = session; focusedCaption = caption; frozenEnglish = source
        self.revision = revision; textView = view; self.beforePronunciation = beforePronunciation
        selectedCourse = course
    }
    func select(range: NSRange, view: UITextView) -> LookupSelection? {
        select(ranges: [range], view: view)
    }
    func select(ranges: [NSRange], view: UITextView) -> LookupSelection? {
        guard let sessionID, let focusedCaption else { return nil }
        do {
            if ranges.count == 1, let selection, selection.range == ranges[0], selection.source == view.text { return selection }
            let selected = try LookupSelection(sessionID: sessionID, captionID: focusedCaption,
                revision: revision, source: view.text ?? "", ranges: ranges)
            invalidateRequest(); stopPronunciation()
            let old = presented; presented = nil; old?.dismiss(animated: true)
            gate.select(selected); selection = selected; message = ""; result = ""
            textView = view
            if let textRange = view.selectedTextRange {
                let rect = view.firstRect(for: textRange).intersection(view.bounds)
                anchor = rect.isNull || rect.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : rect
            }
            return selected
        } catch {
            invalidateRequest(); gate.close(); selection = nil; message = error.localizedDescription
            return nil
        }
    }
    func selectionEnded(owner: UUID, caption: UUID) {
        guard self.owner == owner, focusedCaption == caption, presented == nil else { return }
        close(owner: owner)
    }
    func readerScrolled(owner: UUID) {
        guard !editMenuVisible, presented == nil else { return }
        close(owner: owner)
    }
    func feedback(_ text: String) { message = text }
    func perform(_ action: Action, selected: LookupSelection) {
        guard selection?.id == selected.id else { return }
        self.action = action; message = ""
        switch action {
        case .dictionary:
            guard UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: selected.term) else {
                message = "未找到词典定义"; return
            }
            let dictionary = LookupDictionaryController(term: selected.term)
            dictionary.onClose = { [weak self] in self?.closedPresentation(selectionID: selected.id) }
            present(dictionary, selected: selected, resultSheet: false)
        case .pronunciation: pronounce(selected)
        case .translation, .explanation:
            result = ""; loading = true
            let host = UIHostingController(rootView: LookupResultView(coordinator: self, selectionID: selected.id))
            present(host, selected: selected, resultSheet: true)
            run(selected)
        }
    }
    func retry() { guard let selection else { return }; run(selection) }
    private func run(_ selected: LookupSelection) {
        invalidateRequest(); let token = gate.begin(); loading = true; result = ""; message = ""
        let action = self.action, config = configuration(), context = selectedCourse.isEmpty ? course() : selectedCourse, fake = mock()
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let answer: String
                if action == .translation {
                    guard localTask == nil else { throw WLFailure.message("翻译暂不可用") }
                    await localCancellation?.value
                    try Task.checkCancellation()
                    let provider = local, id = UUID(); localID = id
                    let operation = Task<String, Error> {
                        if fake {
                            try await Task.sleep(for: .milliseconds(100))
                            return "[MOCK] \(selected.term)"
                        }
                        return try await provider.translate(selected.term)
                    }
                    localTask = operation
                    // Keep the slot until the underlying operation actually exits, even if
                    // cancellation is not cooperative. A deadline must not spawn overlaps.
                    Task { [weak self] in
                        _ = await operation.result
                        if self?.localID == id { self?.localTask = nil }
                    }
                    do { answer = try await AsyncDeadline.run(seconds: 4) { try await operation.value } }
                    catch {
                        operation.cancel()
                        await provider.cancel()
                        throw error
                    }
                } else {
                    guard config.mock || !(config.key ?? "").isEmpty else { throw WLFailure.message("未配置 OpenAI Key") }
                    let entry = UsageEntry(scope: .lookup, model: config.model)
                    if !config.mock { try await store.reserveUsage(entry, session: selected.sessionID) }
                    try Task.checkCancellation()
                    let store = self.store
                    answer = try await translator.explain(selected, course: context, config: config, usage: { metadata in
                        // Actual incurred usage belongs to its original lesson even if the
                        // reader closed. SessionStore rejects deleted lessons.
                        try? await store.finishUsage(entry, metadata: metadata, session: selected.sessionID)
                    }, delta: { [weak self] part in
                        await self?.append(part, token: token, selected: selected.id)
                    })
                }
                guard gate.accepts(token, selection: selected.id), !Task.isCancelled else { return }
                result = answer; loading = false
            } catch {
                guard gate.accepts(token, selection: selected.id), !Task.isCancelled else { return }
                loading = false
                if action == .translation { message = "翻译暂不可用" }
                else if let api = error as? APIError {
                    message = [401, 403, 404].contains(api.status) ? "请检查 Key 与模型权限" : "解释暂不可用（\(api.status)）"
                } else if (config.key ?? "").isEmpty && !config.mock { message = "未配置 OpenAI Key" }
                else { message = "解释暂不可用" }
            }
        }
    }
    private func append(_ text: String, token: UUID, selected: UUID) {
        guard gate.accepts(token, selection: selected) else { return }; result += text
    }
    private func pronounce(_ selected: LookupSelection) {
        guard speechState.begin(recordingState: recordingState(), busy: busy()) else {
            message = "暂停后可发音"; return
        }
        beforePronunciation?()
        synthesizer.stopSpeaking(at: .immediate)
        if mock() { message = "[MOCK] 发音"; return }
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" })
                ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("en-") }) else {
            message = "英语语音不可用"; speechState.stopBeforeRecording(); return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audio.setActive(true); ownsSpeechAudio = true
            synthesizer.usesApplicationAudioSession = true
            let utterance = AVSpeechUtterance(string: selected.term); utterance.voice = voice
            synthesizer.speak(utterance)
        } catch { message = "发音暂不可用"; speechState.stopBeforeRecording() }
        // No finish delegate changes the audio session. Start/resume owns its category.
    }
    func prepareForRecording() { close(); stopPronunciation() }
    private func stopPronunciation() {
        synthesizer.stopSpeaking(at: .immediate); speechState.stopBeforeRecording()
        if ownsSpeechAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsSpeechAudio = false
        }
    }
    private func invalidateRequest() {
        request?.cancel(); request = nil; localTask?.cancel()
        if localTask != nil {
            let provider = local, previous = localCancellation
            localCancellation = Task { await previous?.value; await provider.cancel() }
        }
        _ = gate.begin(); loading = false
    }
    func close(owner: UUID? = nil) {
        if let owner, self.owner != owner { return }
        invalidateRequest(); gate.close(); selection = nil; focusedCaption = nil; self.owner = nil
        editMenuVisible = false
        frozenEnglish = ""; message = ""; result = ""; sessionID = nil
        let old = presented; presented = nil; old?.dismiss(animated: true)
        let view = textView; textView = nil
        view?.selectedRange = NSRange(location: 0, length: 0); view?.resignFirstResponder()
        stopPronunciation()
    }
    private func present(_ controller: UIViewController, selected: LookupSelection, resultSheet: Bool) {
        guard let view = textView, let parent = view.lookupViewController, presented == nil else { return }
        if UIDevice.current.userInterfaceIdiom == .pad {
            controller.modalPresentationStyle = .popover
            if resultSheet { controller.preferredContentSize = CGSize(width: 360, height: 360) }
            controller.popoverPresentationController?.sourceView = view
            controller.popoverPresentationController?.sourceRect = anchor
            controller.popoverPresentationController?.permittedArrowDirections = [.up, .down]
        } else {
            controller.modalPresentationStyle = .pageSheet
            if resultSheet {
                controller.sheetPresentationController?.detents = [.medium(), .large()]
                controller.sheetPresentationController?.prefersGrabberVisible = true
            }
        }
        presented = controller; controller.presentationController?.delegate = self
        parent.present(controller, animated: true)
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presented === presentationController.presentedViewController else { return }; close()
    }
    func closedPresentation(selectionID: UUID) {
        guard selection?.id == selectionID else { return }; close()
    }
}

private final class LookupDictionaryController: UIReferenceLibraryViewController {
    var onClose: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onClose?() }
    }
}
private extension UIView {
    var lookupViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder {
            if let controller = next as? UIViewController { return controller }
            responder = next.next
        }
        return nil
    }
}
private struct LookupResultView: View {
    @ObservedObject var coordinator: WordLookupCoordinator
    let selectionID: UUID
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(coordinator.selection?.term ?? "").font(.title3).textSelection(.enabled).accessibilityIdentifier("lookup-term")
                    if coordinator.loading && coordinator.result.isEmpty { ProgressView() }
                    if !coordinator.result.isEmpty { Text(coordinator.result).textSelection(.enabled).accessibilityIdentifier("lookup-result") }
                    if !coordinator.message.isEmpty {
                        Text(coordinator.message).font(.footnote).foregroundStyle(.secondary)
                        Button("重试") { coordinator.retry() }.disabled(coordinator.loading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            .navigationTitle(coordinator.action.rawValue).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { coordinator.closedPresentation(selectionID: selectionID) }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = coordinator.result }
                        .disabled(coordinator.result.isEmpty)
                }
            }
        }.tint(.williamAccent)
        .onDisappear { coordinator.closedPresentation(selectionID: selectionID) }
    }
}
