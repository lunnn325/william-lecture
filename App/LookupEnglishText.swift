import SwiftUI
import UIKit
import WLCore

struct LookupEnglishText: UIViewRepresentable {
    @ObservedObject var lookup: WordLookupCoordinator
    let owner: UUID
    let session: UUID
    let course: String
    let caption: WorkspaceCaption
    let fontSize: CGFloat
    var onFocus: () -> Void
    var beforePronunciation: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> LookupTextView {
        let view = LookupTextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true; view.delegate = context.coordinator
        view.onTouch = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }; coordinator?.focus(view)
        }
        view.onResign = { [weak coordinator = context.coordinator] in coordinator?.ended() }
        return view
    }
    func updateUIView(_ view: LookupTextView, context: Context) {
        context.coordinator.parent = self
        let focused = lookup.owner == owner && lookup.focusedCaption == caption.id
        let source = focused ? lookup.frozenEnglish : caption.english
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let text = NSAttributedString(string: source, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: UIColor(Color.williamSecondary).resolvedColor(with: view.traitCollection), .paragraphStyle: paragraph
        ])
        // SwiftUI-backed dynamic UIColor providers can compare unequal on a
        // caption update. Reassigning attributedText revokes UIKit's selection.
        // Freeze attributes as well as source during lookup; refresh on close.
        if view.text != source || (!focused && !view.attributedText.isEqual(to: text)) {
            context.coordinator.updating = true; view.attributedText = text; context.coordinator.updating = false
        }
        view.accessibilityIdentifier = "caption-english-\(caption.id.uuidString)"
        view.accessibilityLabel = source
        view.onTouch = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }; coordinator?.focus(view)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LookupTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LookupEnglishText
        var updating = false
        init(_ parent: LookupEnglishText) { self.parent = parent }
        func focus(_ view: UITextView) {
            parent.onFocus()
            parent.lookup.focus(owner: parent.owner, session: parent.session, caption: parent.caption.id,
                source: view.text ?? "", revision: parent.caption.revision, course: parent.course, view: view,
                beforePronunciation: parent.beforePronunciation)
        }
        func ended() { parent.lookup.selectionEnded(owner: parent.owner, caption: parent.caption.id) }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating, textView.selectedRange.length > 0 else { return }
            focus(textView); _ = parent.lookup.select(range: textView.selectedRange, view: textView)
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            menu(textView, ranges: [range])
        }
        func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu? {
            menu(textView, ranges: ranges.map(\.rangeValue))
        }
        func textView(_ textView: UITextView, willPresentEditMenuWith animator: any UIEditMenuInteractionAnimating) {
            parent.lookup.editMenuVisible = true
        }
        func textView(_ textView: UITextView, willDismissEditMenuWith animator: any UIEditMenuInteractionAnimating) {
            animator.addCompletion { [weak self] in self?.parent.lookup.editMenuVisible = false }
        }
        private func menu(_ textView: UITextView, ranges: [NSRange]) -> UIMenu? {
            focus(textView)
            guard let selected = parent.lookup.select(ranges: ranges, view: textView) else { return UIMenu(children: []) }
            let actions: [UIMenuElement] = [WordLookupCoordinator.Action.dictionary, .pronunciation, .translation, .explanation].map { action in
                UIAction(title: action.rawValue) { [weak self] _ in self?.parent.lookup.perform(action, selected: selected) }
            }
            let copy = UIAction(title: "复制") { _ in UIPasteboard.general.string = selected.term }
            return UIMenu(children: actions + [copy])
        }
    }
}

final class LookupTextView: UITextView {
    var onTouch: (() -> Void)?
    var onResign: (() -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch?(); super.touchesBegan(touches, with: event)
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }; return resigned
    }
}
