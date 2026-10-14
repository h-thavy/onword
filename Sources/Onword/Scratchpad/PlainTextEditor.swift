import AppKit
import SwiftUI

/// An NSTextView wrapped for SwiftUI. Used instead of `TextEditor` so dictation can insert at the
/// cursor of Onword's own windows without going through the Accessibility API (an app querying its
/// own Accessibility tree from the main thread would deadlock).
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 15)
    var placeholder: String = ""
    /// Changes when a different document is shown, so the cursor resets.
    var documentID: AnyHashable?
    /// Optional styling (the Scratchpad window): fixed line height, text and caret colours, insets.
    var lineHeight: CGFloat?
    var textColor: NSColor?
    var caretColor: NSColor?
    var inset = NSSize(width: 18, height: 16)
    /// Extra scrollable space below the text, so it can clear floating buttons.
    var bottomOverscroll: CGFloat = 0
    /// Put the cursor in the editor when it appears (the Scratchpad); notes leave focus alone.
    var autoFocus = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.font = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        applyStyle(to: textView, in: scrollView)
        textView.string = text
        restyleText(in: textView)
        context.coordinator.placeholder(placeholder, in: textView)
        OwnWindowInserter.lastEditor = textView
        focus(textView)
        return scrollView
    }

    /// Puts the cursor in the editor so you can type or dictate straight away.
    private func focus(_ textView: NSTextView) {
        guard autoFocus else { return }
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    }

    /// Font, colours, insets and line height. A CSS-style line height is a line spacing plus half of
    /// the extra space above the first line, so the caret keeps the font's height.
    private func applyStyle(to textView: NSTextView, in scrollView: NSScrollView) {
        var attributes = textView.typingAttributes
        attributes[.font] = font
        if let textColor {
            textView.textColor = textColor
            attributes[.foregroundColor] = textColor
        }
        if let caretColor { textView.insertionPointColor = caretColor }
        var inset = inset
        if let lineHeight {
            let natural = ceil(font.ascender - font.descender + font.leading)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = max(0, lineHeight - natural)
            attributes[.paragraphStyle] = style
            textView.defaultParagraphStyle = style
            inset.height += max(0, lineHeight - natural) / 2
        }
        textView.typingAttributes = attributes
        textView.textContainerInset = inset
        if bottomOverscroll > 0 {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomOverscroll, right: 0)
        }
    }

    /// Re-applies the typing attributes to all text after it's replaced wholesale.
    private func restyleText(in textView: NSTextView) {
        guard lineHeight != nil || textColor != nil, let storage = textView.textStorage else { return }
        storage.setAttributes(textView.typingAttributes, range: NSRange(location: 0, length: storage.length))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if context.coordinator.documentID != documentID {
            context.coordinator.documentID = documentID
            textView.string = text
            restyleText(in: textView)
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.undoManager?.removeAllActions()
            focus(textView)
        } else if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            restyleText(in: textView)
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        context.coordinator.placeholder(placeholder, in: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        var documentID: AnyHashable?
        private var placeholderField: NSTextField?

        init(_ parent: PlainTextEditor) {
            self.parent = parent
            documentID = parent.documentID
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            placeholder(parent.placeholder, in: textView)
        }

        func placeholder(_ text: String, in textView: NSTextView) {
            if placeholderField == nil, !text.isEmpty {
                let field = NSTextField(labelWithString: text)
                field.textColor = .placeholderTextColor
                field.font = textView.font
                field.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(field)
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: parent.inset.width + 5),
                    field.topAnchor.constraint(equalTo: textView.topAnchor, constant: parent.inset.height),
                ])
                placeholderField = field
            }
            placeholderField?.isHidden = !textView.string.isEmpty
        }
    }
}

/// Dictation into Onword's own windows: inserts at the cursor of whichever text view has focus.
enum OwnWindowInserter {
    /// The Scratchpad editor, used when no text field in Onword has keyboard focus.
    static weak var lastEditor: NSTextView?

    static var focusedTextView: NSTextView? {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView { return textView }
        // The floating Scratchpad panel can be key while another app stays frontmost.
        if let textView = MainActor.assumeIsolated({ ScratchpadWindow.shared.keyTextView }) { return textView }
        if let editor = lastEditor, editor.window?.isVisible == true { return editor }
        return nil
    }

    /// Text before/after the cursor, for the same casing/spacing rules used in other apps.
    static func context() -> (before: String, after: String) {
        guard let textView = focusedTextView else { return ("", "") }
        let string = textView.string as NSString
        let range = textView.selectedRange()
        let start = min(range.location, string.length)
        let end = min(range.location + range.length, string.length)
        return (String(string.substring(to: start).suffix(TextContext.maxContext)),
                String(string.substring(from: end).prefix(TextContext.maxContext)))
    }

    static func insert(_ text: String) -> Bool {
        guard let textView = focusedTextView, textView.isEditable else { return false }
        textView.insertText(text, replacementRange: textView.selectedRange())
        return true
    }
}
