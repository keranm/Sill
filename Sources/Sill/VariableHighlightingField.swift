import SwiftUI
import AppKit

/// How a `{name}` reference in the API client reads at a glance: red when it
/// won't resolve to anything (the exact mistake that prompted this — typing
/// `{root_url}` when the environment actually holds `root_uri`), green when
/// it's a real variable in the active environment, and the accent colour for
/// `$`-prefixed built-ins (`{$timestamp}`, `{$path}`, …) which always resolve
/// regardless of which environment is selected.
enum APIVariableTokenKind {
    case builtin
    case known
    case unknown

    var color: NSColor {
        switch self {
        case .builtin: NSColor(Tokens.accent)
        case .known: NSColor(Tokens.success)
        case .unknown: NSColor(Tokens.danger)
        }
    }
}

/// Shared coloring logic between the single-line (`HighlightingTextField`)
/// and multi-line (`HighlightingTextEditor`) controls — finds every
/// `{name}` occurrence and colors just that span, leaving everything else
/// (including stray JSON braces, which never match the identifier grammar
/// below) in the ordinary ink color.
enum APIVariableHighlighter {
    static func coloredAttributedString(for text: String, font: NSFont, classify: (String) -> APIVariableTokenKind) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(Tokens.ink)])
        for (range, name) in variableRanges(in: text) {
            let nsRange = NSRange(range, in: text)
            result.addAttribute(.foregroundColor, value: classify(name).color, range: nsRange)
        }
        return result
    }

    /// Matches the same `{identifier}` grammar the resolver itself scans for
    /// (letters/digits/underscore/`$`, no spaces) — anything else inside
    /// braces (a JSON literal, stray text) is left uncolored because it was
    /// never going to be treated as a variable at substitution time either.
    private static func variableRanges(in text: String) -> [(Range<String.Index>, String)] {
        var results: [(Range<String.Index>, String)] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "{" else {
                i = text.index(after: i)
                continue
            }
            var j = text.index(after: i)
            var name = ""
            while j < text.endIndex, text[j] != "}", text[j] != "{" {
                let c = text[j]
                guard c.isLetter || c.isNumber || c == "_" || c == "$" else { break }
                name.append(c)
                j = text.index(after: j)
            }
            if j < text.endIndex, text[j] == "}", !name.isEmpty {
                let end = text.index(after: j)
                results.append((i..<end, name))
                i = end
            } else {
                i = text.index(after: i)
            }
        }
        return results
    }
}

/// A single-line text field (URL bar, header key/value) that colors
/// `{variable}` references live as you type, backed by a real `NSTextField`
/// since SwiftUI's `String`-bound `TextField` has no way to color a
/// substring. Attributes are edited in place (never replacing the backing
/// `NSTextStorage` wholesale) so the cursor/selection survives every
/// keystroke's recoloring pass.
struct HighlightingTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var fontSize: CGFloat = 12
    let classify: (String) -> APIVariableTokenKind
    var onFocusChange: ((Bool) -> Void)?
    var onSubmit: (() -> Void)?

    private var nsFont: NSFont { NSFont(name: Tokens.fontFamily, size: fontSize) ?? .systemFont(ofSize: fontSize) }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, classify: classify, font: nsFont, onFocusChange: onFocusChange, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.attributedStringValue = APIVariableHighlighter.coloredAttributedString(for: text, font: nsFont, classify: classify)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.classify = classify
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.onSubmit = onSubmit
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.recolor(nsView)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var classify: (String) -> APIVariableTokenKind
        let font: NSFont
        var onFocusChange: ((Bool) -> Void)?
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, classify: @escaping (String) -> APIVariableTokenKind, font: NSFont, onFocusChange: ((Bool) -> Void)?, onSubmit: (() -> Void)?) {
            self.text = text
            self.classify = classify
            self.font = font
            self.onFocusChange = onFocusChange
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
            recolor(field)
        }

        func controlTextDidBeginEditing(_ obj: Notification) { onFocusChange?(true) }
        func controlTextDidEndEditing(_ obj: Notification) { onFocusChange?(false) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), let onSubmit else { return false }
            onSubmit()
            return true
        }

        /// Recolors by mutating attributes on the existing text storage
        /// (while actively editing) or the field's own attributed value
        /// (when not) — never by replacing the whole string, which would
        /// otherwise reset the cursor to the end on every keystroke.
        func recolor(_ field: NSTextField) {
            let attributed = APIVariableHighlighter.coloredAttributedString(for: field.stringValue, font: font, classify: classify)
            if let editor = field.currentEditor() as? NSTextView, let storage = editor.textStorage {
                let selectedRanges = editor.selectedRanges
                storage.setAttributedString(attributed)
                editor.selectedRanges = selectedRanges
            } else {
                field.attributedStringValue = attributed
            }
        }
    }
}

/// The multi-line equivalent for the request body — same coloring, same
/// in-place attribute mutation to preserve the cursor, wrapping `NSTextView`
/// in a scroll view the way SwiftUI's own `TextEditor` does internally.
struct HighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12
    let classify: (String) -> APIVariableTokenKind

    private var nsFont: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, classify: classify, font: nsFont)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.font = nsFont
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.drawsBackground = false
        textView.string = text
        textView.textStorage?.setAttributedString(APIVariableHighlighter.coloredAttributedString(for: text, font: nsFont, classify: classify))

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.classify = classify
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.recolor(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var classify: (String) -> APIVariableTokenKind
        let font: NSFont

        init(text: Binding<String>, classify: @escaping (String) -> APIVariableTokenKind, font: NSFont) {
            self.text = text
            self.classify = classify
            self.font = font
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            recolor(textView)
        }

        func recolor(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selectedRanges = textView.selectedRanges
            storage.setAttributedString(APIVariableHighlighter.coloredAttributedString(for: textView.string, font: font, classify: classify))
            textView.selectedRanges = selectedRanges
        }
    }
}
