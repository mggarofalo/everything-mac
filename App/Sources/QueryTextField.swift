import AppKit
import SwiftUI

/// SwiftUI's TextField cannot decorate ranges inside editable text. This bridge
/// keeps a plain String as the only source of truth and uses a layout attribute
/// solely to draw recognized Boolean operators as rounded pills.
struct QueryTextField: NSViewRepresentable {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onTextChange: () -> Void
    var onTab: (_ text: String, _ selection: NSRange) -> String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> QueryEditorContainer {
        let view = QueryEditorContainer()
        view.textView.delegate = context.coordinator
        context.coordinator.textView = view.textView
        view.textView.string = text
        context.coordinator.styleOperators()
        return view
    }

    func updateNSView(_ view: QueryEditorContainer, context: Context) {
        context.coordinator.parent = self
        if view.textView.string != text {
            let selection = view.textView.selectedRange()
            view.textView.string = text
            view.textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length), length: 0
            ))
            context.coordinator.styleOperators()
        }
        view.placeholder.isHidden = !text.isEmpty
        if focused.wrappedValue, view.window?.firstResponder !== view.textView {
            view.window?.makeFirstResponder(view.textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QueryTextField
        weak var textView: NSTextView?
        private var applyingStyle = false

        init(_ parent: QueryTextField) { self.parent = parent }

        func textDidBeginEditing(_ notification: Notification) {
            parent.focused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.focused.wrappedValue = false
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingStyle, let textView else { return }
            parent.text = textView.string
            styleOperators()
            parent.onTextChange()
            (textView.superview?.superview as? QueryEditorContainer)?.placeholder.isHidden =
                !textView.string.isEmpty
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertTab(_:)) else { return false }
            guard let replacement = parent.onTab(textView.string, textView.selectedRange()) else {
                return false
            }
            parent.text = replacement
            textView.string = replacement
            textView.setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
            styleOperators()
            parent.onTextChange()
            return true
        }

        func styleOperators() {
            guard let textView, let storage = textView.textStorage else { return }
            applyingStyle = true
            defer { applyingStyle = false }
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(PillLayoutManager.operatorAttribute, range: fullRange)
            storage.removeAttribute(.foregroundColor, range: fullRange)
            storage.removeAttribute(.font, range: fullRange)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15), range: fullRange)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
            for range in Self.operatorRanges(in: textView.string) {
                storage.addAttribute(PillLayoutManager.operatorAttribute, value: true, range: range)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                     range: range)
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                     range: range)
            }
            storage.endEditing()
            textView.typingAttributes = [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private static func operatorRanges(in source: String) -> [NSRange] {
            let string = source as NSString
            let delimiters = CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "()")
            )
            var ranges: [NSRange] = []
            var index = 0
            var quoted = false
            while index < string.length {
                guard let scalar = UnicodeScalar(string.character(at: index)) else {
                    index += 1
                    continue
                }
                if scalar == "\"" { quoted.toggle(); index += 1; continue }
                if delimiters.contains(scalar) { index += 1; continue }
                let start = index
                var tokenWasQuoted = quoted
                while index < string.length {
                    guard let current = UnicodeScalar(string.character(at: index)) else {
                        index += 1
                        continue
                    }
                    if current == "\"" {
                        quoted.toggle()
                        tokenWasQuoted = true
                        index += 1
                        continue
                    }
                    if !quoted, delimiters.contains(current) { break }
                    index += 1
                }
                let range = NSRange(location: start, length: index - start)
                let token = string.substring(with: range)
                if !tokenWasQuoted, ["AND", "OR", "XOR", "NOT"].contains(token) {
                    ranges.append(range)
                }
            }
            return ranges
        }
    }
}

final class QueryEditorContainer: NSView {
    let textView: NSTextView
    let placeholder = NSTextField(labelWithString: "Search everything…")
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = PillLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                               height: 24))
        container.widthTracksTextView = false
        container.heightTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = .systemFont(ofSize: 15)
        textView.setAccessibilityLabel("Search")

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        addSubview(scrollView)

        placeholder.textColor = .placeholderTextColor
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.isBezeled = false
        placeholder.drawsBackground = false
        placeholder.isEditable = false
        placeholder.isSelectable = false
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        textView.frame = NSRect(x: 0, y: 0,
                                width: max(bounds.width, textView.intrinsicContentSize.width),
                                height: bounds.height)
        placeholder.sizeToFit()
        let textOrigin = textView.textContainerOrigin.x
            + (textView.textContainer?.lineFragmentPadding ?? 0)
        placeholder.frame.origin = NSPoint(x: floor(textOrigin),
                                            y: floor((bounds.height - placeholder.frame.height) / 2))
    }
}

final class PillLayoutManager: NSLayoutManager {
    static let operatorAttribute = NSAttributedString.Key("EverythingMacBooleanOperator")

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let container = textContainers.first else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow,
                                                  actualGlyphRange: nil)
        textStorage.enumerateAttribute(Self.operatorAttribute, in: characterRange) {
            value, range, _ in
            guard value != nil else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range,
                                             actualCharacterRange: nil)
            self.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                         withinSelectedGlyphRange: NSRange(location: NSNotFound,
                                                                          length: 0),
                                         in: container) { rect, _ in
                let pill = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: 1)
                NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
            }
        }
    }
}
