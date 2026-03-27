import AppKit
import SwiftUI

/// Single-surface markdown notes editor with live structural styling.
struct NotesView: View {
    let sessionID: String
    let library: SessionLibrary
    var bottomContentInset: CGFloat = 0
    var onTextChange: ((String) -> Void)? = nil

    @State private var text: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var isLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTextView(
                text: $text,
                placeholder: "Write notes...",
                bottomContentInset: bottomContentInset
            )
                .padding(20)
                .background(Color.warmBackground)
        }
        .task {
            let loaded = await library.loadNotes(for: sessionID)
            let stored = NoteEditorBottomSpacer.storedText(from: loaded)
            text = NoteEditorBottomSpacer.editorText(fromStored: stored)
            onTextChange?(stored)
            isLoaded = true
        }
        .onChange(of: text) {
            let stored = NoteEditorBottomSpacer.storedText(from: text)
            onTextChange?(stored)
            guard isLoaded else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await library.saveNotes(for: sessionID, text: stored)
            }
        }
    }
}

private struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let bottomContentInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, placeholder: placeholder)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomContentInset, right: 0)
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 18
        scrollView.layer?.masksToBounds = true
        scrollView.layer?.backgroundColor = NSColor(Color.warmCardBg).cgColor
        scrollView.layer?.borderColor = NSColor(Color.warmBorder).cgColor
        scrollView.layer?.borderWidth = 1

        let textView = PlaceholderTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 26)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.placeholder = placeholder

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applyText(text)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        nsView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomContentInset, right: 0)
        context.coordinator.placeholder = placeholder
        context.coordinator.textView?.placeholder = placeholder
        if context.coordinator.textView?.string != text {
            context.coordinator.applyText(text)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var placeholder: String
        weak var textView: PlaceholderTextView?
        private var isApplying = false

        init(text: Binding<String>, placeholder: String) {
            self._text = text
            self.placeholder = placeholder
        }

        @MainActor
        func textDidChange(_ notification: Notification) {
            guard let textView, !isApplying else { return }
            let stored = NoteEditorBottomSpacer.storedText(from: textView.string)
            let display = NoteEditorBottomSpacer.editorText(fromStored: stored)
            if display != textView.string {
                let selectedRanges = textView.selectedRanges
                let maxCursorLocation = max(
                    0,
                    (display as NSString).length - NoteEditorBottomSpacer.spacerLength(for: display)
                )
                let adjustedRanges = selectedRanges.map { value -> NSValue in
                    let range = value.rangeValue
                    let location = min(range.location, maxCursorLocation)
                    let length = min(range.length, max(0, maxCursorLocation - location))
                    return NSValue(range: NSRange(location: location, length: length))
                }
                isApplying = true
                textView.string = display
                textView.selectedRanges = adjustedRanges
                isApplying = false
            }
            text = display
            style(textView: textView)
        }

        @MainActor
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderTextView, !isApplying else { return }
            updateTypingAttributes(for: textView)
        }

        @MainActor
        func applyText(_ string: String) {
            guard let textView else { return }
            let normalized = NoteEditorBottomSpacer.editorText(fromStored: string)
            isApplying = true
            textView.string = normalized
            style(textView: textView)
            isApplying = false
        }

        @MainActor
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let textView = textView as? PlaceholderTextView else { return false }

            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                return adjustIndentation(in: textView, delta: 1)
            case #selector(NSResponder.insertBacktab(_:)):
                return adjustIndentation(in: textView, delta: -1)
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                return continueList(in: textView)
            default:
                return false
            }
        }

        @MainActor
        private func style(textView: PlaceholderTextView) {
            let selectedRanges = textView.selectedRanges
            let text = textView.string
            let attributed = MarkdownStyler.makeAttributedString(text: text)

            textView.textStorage?.setAttributedString(attributed)
            textView.selectedRanges = selectedRanges
            updateTypingAttributes(for: textView)
            textView.needsDisplay = true
        }

        @MainActor
        private func adjustIndentation(in textView: PlaceholderTextView, delta: Int) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound else { return false }

            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: selectedRange)
            let contentRange = lineContentRange(for: lineRange, in: nsText)
            let rawLine = nsText.substring(with: contentRange)

            guard let item = EditorListItem(rawLine: rawLine) else { return false }

            let newIndentSpaces = max(0, item.indentSpaces + (delta * MarkdownListNormalizer.indentWidth))
            guard newIndentSpaces != item.indentSpaces else { return true }

            let newLine = item.line(withIndentSpaces: newIndentSpaces)
            let updatedText = nsText.replacingCharacters(in: contentRange, with: newLine)

            let caretOffset = max(0, selectedRange.location - contentRange.location)
            let newCaretLocation = contentRange.location + min(
                newLine.utf16.count,
                max(0, caretOffset + ((newIndentSpaces - item.indentSpaces)))
            )

            commitEdit(
                in: textView,
                text: updatedText,
                selectedRange: NSRange(location: newCaretLocation, length: selectedRange.length)
            )
            return true
        }

        @MainActor
        private func continueList(in textView: PlaceholderTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound else { return false }

            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: selectedRange)
            let contentRange = lineContentRange(for: lineRange, in: nsText)
            let rawLine = nsText.substring(with: contentRange)

            guard let item = EditorListItem(rawLine: rawLine) else { return false }

            if item.isEffectivelyEmpty {
                if item.indentSpaces > 0 {
                    let detentedIndentSpaces = max(0, item.indentSpaces - MarkdownListNormalizer.indentWidth)
                    let detentedLine = item.line(withIndentSpaces: detentedIndentSpaces)
                    let updatedText = nsText.replacingCharacters(in: contentRange, with: detentedLine)
                    let newCursorLocation = contentRange.location + (detentedLine as NSString).length

                    commitEdit(
                        in: textView,
                        text: updatedText,
                        selectedRange: NSRange(location: newCursorLocation, length: 0)
                    )
                } else {
                    let updatedText = nsText.replacingCharacters(in: contentRange, with: "")
                    commitEdit(
                        in: textView,
                        text: updatedText,
                        selectedRange: NSRange(location: contentRange.location, length: 0)
                    )
                }
                return true
            }

            let insertion = "\n" + item.continuationPrefix
            let updatedText = nsText.replacingCharacters(in: selectedRange, with: insertion)
            let newCursorLocation = selectedRange.location + insertion.utf16.count

            commitEdit(
                in: textView,
                text: updatedText,
                selectedRange: NSRange(location: newCursorLocation, length: 0)
            )
            return true
        }

        @MainActor
        private func commitEdit(
            in textView: PlaceholderTextView,
            text newText: String,
            selectedRange: NSRange
        ) {
            let normalized = NoteEditorBottomSpacer.editorText(fromStored: newText)
            isApplying = true
            textView.string = normalized
            text = normalized
            style(textView: textView)
            let maxCursorLocation = max(
                0,
                (normalized as NSString).length - NoteEditorBottomSpacer.spacerLength(for: normalized)
            )
            let clampedLocation = min(selectedRange.location, maxCursorLocation)
            let clampedLength = min(selectedRange.length, max(0, maxCursorLocation - clampedLocation))
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
            updateTypingAttributes(for: textView)
            isApplying = false
        }

        @MainActor
        private func updateTypingAttributes(for textView: PlaceholderTextView) {
            var typingAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor(Color.readingText)
            ]

            guard let textStorage = textView.textStorage else {
                textView.typingAttributes = typingAttributes
                return
            }

            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString

            if textStorage.length > 0 {
                let attributeIndex = min(max(selectedRange.location - 1, 0), textStorage.length - 1)
                let existingAttributes = textStorage.attributes(at: attributeIndex, effectiveRange: nil)
                if let paragraphStyle = existingAttributes[.paragraphStyle] {
                    typingAttributes[.paragraphStyle] = paragraphStyle
                }
            }

            let clampedLocation = min(max(selectedRange.location, 0), text.length)
            if text.length > 0 {
                let lineAnchor = min(clampedLocation, max(text.length - 1, 0))
                let lineRange = text.lineRange(for: NSRange(location: lineAnchor, length: 0))
                let rawLine = text.substring(with: lineContentRange(for: lineRange, in: text))
                let trimmedLine = rawLine.trimmingCharacters(in: .newlines)

                if trimmedLine.hasPrefix("# ") {
                    typingAttributes[.font] = NSFont.systemFont(ofSize: 18, weight: .bold)
                } else if trimmedLine.hasPrefix("## ") {
                    typingAttributes[.font] = NSFont.systemFont(ofSize: 16, weight: .bold)
                } else if trimmedLine.hasPrefix("### ") {
                    typingAttributes[.font] = NSFont.systemFont(ofSize: 14, weight: .semibold)
                } else if trimmedLine.hasPrefix("> ") {
                    typingAttributes[.foregroundColor] = NSColor(Color.readingText.opacity(0.68))
                }
            }

            textView.typingAttributes = typingAttributes
        }

        private func lineContentRange(for lineRange: NSRange, in text: NSString) -> NSRange {
            var length = lineRange.length

            while length > 0 {
                let scalar = text.character(at: lineRange.location + length - 1)
                if scalar == 10 || scalar == 13 {
                    length -= 1
                } else {
                    break
                }
            }

            return NSRange(location: lineRange.location, length: length)
        }
    }
}

private enum NoteEditorBottomSpacer {
    private static let spacerLineMarker = "\u{200B}"
    private static let spacerLineCount = 5
    private static let spacerBlock = Array(repeating: spacerLineMarker, count: spacerLineCount).joined(separator: "\n")
    private static let spacerBlockWithLeadingNewline = "\n" + spacerBlock

    static func editorText(fromStored text: String) -> String {
        let stored = storedText(from: text)
        guard !stored.isEmpty else { return "" }
        if stored.hasSuffix("\n") {
            return stored + spacerBlock
        }
        return stored + spacerBlockWithLeadingNewline
    }

    static func storedText(from text: String) -> String {
        MarkdownListNormalizer.normalize(removingSpacer(from: text))
    }

    static func spacerLength(for editorText: String) -> Int {
        if editorText.hasSuffix(spacerBlockWithLeadingNewline) {
            return spacerBlockWithLeadingNewline.utf16.count
        }

        if editorText.hasSuffix(spacerBlock) {
            return spacerBlock.utf16.count
        }

        return 0
    }

    private static func removingSpacer(from text: String) -> String {
        if text.hasSuffix(spacerBlockWithLeadingNewline) {
            return String(text.dropLast(spacerBlockWithLeadingNewline.count))
        }

        if text.hasSuffix(spacerBlock) {
            return String(text.dropLast(spacerBlock.count))
        }

        return text
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholder: String = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCustomBullets(in: dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(Color.warmTextMuted)
        ]

        let inset = textContainerInset
        let rect = NSRect(
            x: inset.width,
            y: inset.height + 2,
            width: bounds.width - inset.width * 2,
            height: 22
        )
        placeholder.draw(in: rect, withAttributes: attributes)
    }

    private func drawCustomBullets(in dirtyRect: NSRect) {
        guard let layoutManager else { return }

        let nsText = string as NSString
        var location = 0

        while location < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = lineContentRange(for: lineRange, in: nsText)
            let rawLine = nsText.substring(with: contentRange)
            let indentSpaces = rawLine.prefix { $0 == " " }.count
            let content = String(rawLine.dropFirst(indentSpaces))

            guard let marker = content.first,
                  MarkdownListNormalizer.isBullet(marker),
                  content.dropFirst().first == " " else {
                location = NSMaxRange(lineRange)
                continue
            }

            let bulletCharacterRange = NSRange(location: contentRange.location + indentSpaces, length: 1)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: bulletCharacterRange.location)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )

            let origin = textContainerOrigin
            let indentLevel = indentSpaces / MarkdownListNormalizer.indentWidth
            let textStartX = origin.x
                + CGFloat(indentLevel) * MarkdownListLayoutMetrics.indentStep
                + MarkdownListLayoutMetrics.bulletMarkerWidth
                + MarkdownListLayoutMetrics.markerGap
            let markerY = origin.y + lineRect.midY
            drawBullet(marker: marker, textStartX: textStartX, centerY: markerY)

            location = NSMaxRange(lineRange)
        }
    }

    private func drawBullet(marker: Character, textStartX: CGFloat, centerY: CGFloat) {
        let color = NSColor(Color.warmTextMuted)

        switch marker {
        case "•":
            let size: CGFloat = 4.6
            let rect = NSRect(
                x: textStartX - MarkdownListLayoutMetrics.bulletToTextGap - size,
                y: centerY - (size / 2),
                width: size,
                height: size
            )
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case "◦":
            let size: CGFloat = 3.9
            let rect = NSRect(
                x: textStartX - MarkdownListLayoutMetrics.bulletToTextGap - size,
                y: centerY - (size / 2),
                width: size,
                height: size
            )
            color.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 1.0
            path.stroke()
        case "▪":
            let size: CGFloat = 3.9
            let rect = NSRect(
                x: textStartX - MarkdownListLayoutMetrics.bulletToTextGap - size,
                y: centerY - (size / 2),
                width: size,
                height: size
            )
            color.setFill()
            NSBezierPath(rect: rect).fill()
        default:
            break
        }
    }

    private func lineContentRange(for lineRange: NSRange, in text: NSString) -> NSRange {
        var length = lineRange.length

        while length > 0 {
            let scalar = text.character(at: lineRange.location + length - 1)
            if scalar == 10 || scalar == 13 {
                length -= 1
            } else {
                break
            }
        }

        return NSRange(location: lineRange.location, length: length)
    }
}

private enum MarkdownListLayoutMetrics {
    static let indentStep: CGFloat = 24
    static let markerGap: CGFloat = 8
    static let bulletMarkerWidth: CGFloat = 11
    static let bulletToTextGap: CGFloat = 7
    static let numberedMarkerBaseWidth: CGFloat = 14
}

private enum MarkdownListNormalizer {
    static let indentWidth = 2
    private static let bulletCycle = ["•", "◦", "▪"]

    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let lines = text.components(separatedBy: .newlines)
        return lines.map(normalize(line:)).joined(separator: "\n")
    }

    private static func normalize(line: String) -> String {
        let indentSpaces = line.prefix { $0 == " " }.count
        let indent = String(repeating: " ", count: indentSpaces)
        let content = String(line.dropFirst(indentSpaces))
        let indentLevel = indentSpaces / indentWidth

        if let first = content.first,
           ["-", "*", "•", "◦", "▪"].contains(first),
           content.dropFirst().first == " " {
            return indent + bullet(for: indentLevel) + " " + content.dropFirst(2)
        }

        return line
    }

    static func bullet(for indentLevel: Int) -> String {
        bulletCycle[indentLevel % bulletCycle.count]
    }

    static func isBullet(_ character: Character) -> Bool {
        ["•", "◦", "▪"].contains(character)
    }
}

private struct EditorListItem {
    let indentSpaces: Int
    let kind: Kind
    let content: String

    enum Kind {
        case bullet
        case numbered(Int)
    }

    init?(rawLine: String) {
        let indentSpaces = rawLine.prefix { $0 == " " }.count
        let contentStart = String(rawLine.dropFirst(indentSpaces))
        self.indentSpaces = indentSpaces

        if let first = contentStart.first,
           ["•", "◦", "▪", "-", "*"].contains(first),
           contentStart.dropFirst().first == " " {
            self.kind = .bullet
            self.content = String(contentStart.dropFirst(2))
            return
        }

        if let match = contentStart.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let marker = String(contentStart[match])
            let numberPart = marker.dropLast(2)
            self.kind = .numbered(Int(numberPart) ?? 1)
            self.content = String(contentStart[match.upperBound...])
            return
        }

        return nil
    }

    var isEffectivelyEmpty: Bool {
        content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var continuationPrefix: String {
        String(repeating: " ", count: indentSpaces) + markerString(forIndentSpaces: indentSpaces)
    }

    func line(withIndentSpaces newIndentSpaces: Int) -> String {
        String(repeating: " ", count: newIndentSpaces) + markerString(forIndentSpaces: newIndentSpaces) + content
    }

    private func markerString(forIndentSpaces indentSpaces: Int) -> String {
        switch kind {
        case .bullet:
            return MarkdownListNormalizer.bullet(for: indentSpaces / MarkdownListNormalizer.indentWidth) + " "
        case .numbered(let number):
            return "\(number). "
        }
    }
}

private enum MarkdownStyler {
    private static var bodyFont: NSFont {
        NSFont.systemFont(ofSize: 14, weight: .regular)
    }

    private static var minimumBodyLineHeight: CGFloat {
        bodyFont.ascender - bodyFont.descender + bodyFont.leading
    }

    static func makeAttributedString(text: String) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let attributed = NSMutableAttributedString(string: text)

        attributed.addAttributes([
            .font: bodyFont,
            .foregroundColor: NSColor(Color.readingText)
        ], range: fullRange)

        let paragraphRanges = lineRanges(in: text)
        for range in paragraphRanges {
            let line = (text as NSString).substring(with: range)
            style(line: line, range: range, in: attributed)
        }

        applyInlineEmphasis(in: attributed)
        return attributed
    }

    private static func lineRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var location = 0

        while location < nsText.length {
            let range = nsText.lineRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }

        if nsText.length == 0 {
            ranges.append(NSRange(location: 0, length: 0))
        }

        return ranges
    }

    private static func style(line rawLine: String, range: NSRange, in attributed: NSMutableAttributedString) {
        let line = rawLine.trimmingCharacters(in: .newlines)
        let indentSpaces = rawLine.prefix { $0 == " " }.count
        let indentLevel = indentSpaces / 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.paragraphSpacing = 2
        paragraph.minimumLineHeight = minimumBodyLineHeight
        paragraph.firstLineHeadIndent = CGFloat(indentLevel) * MarkdownListLayoutMetrics.indentStep
        paragraph.headIndent = paragraph.firstLineHeadIndent

        attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)

        if line.hasPrefix("# ") {
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 18, weight: .bold)
            ], range: range)
            if let prefixRange = headingLayoutPrefixRange(in: rawLine, lineRange: range, markerCount: 1) {
                collapse(range: prefixRange, in: attributed)
            }
            return
        }

        if line.hasPrefix("## ") {
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 16, weight: .bold)
            ], range: range)
            if let prefixRange = headingLayoutPrefixRange(in: rawLine, lineRange: range, markerCount: 2) {
                collapse(range: prefixRange, in: attributed)
            }
            return
        }

        if line.hasPrefix("### ") {
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ], range: range)
            if let prefixRange = headingLayoutPrefixRange(in: rawLine, lineRange: range, markerCount: 3) {
                collapse(range: prefixRange, in: attributed)
            }
            return
        }

        if let bulletLayoutPrefixRange = bulletLayoutPrefixRange(in: rawLine, lineRange: range) {
            let baseIndent = CGFloat(indentLevel) * MarkdownListLayoutMetrics.indentStep
            let textIndent = baseIndent
                + MarkdownListLayoutMetrics.bulletMarkerWidth
                + MarkdownListLayoutMetrics.markerGap
            paragraph.firstLineHeadIndent = textIndent
            paragraph.headIndent = textIndent
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 0.1, weight: .regular),
                .foregroundColor: NSColor.clear
            ], range: bulletLayoutPrefixRange)
            return
        }

        if let numberedPrefix = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let prefixWidth = CGFloat(line.distance(from: numberedPrefix.lowerBound, to: numberedPrefix.upperBound)) * 7
            let baseIndent = CGFloat(indentLevel) * MarkdownListLayoutMetrics.indentStep
            paragraph.firstLineHeadIndent = baseIndent
            paragraph.headIndent = baseIndent + max(MarkdownListLayoutMetrics.numberedMarkerBaseWidth, prefixWidth) + MarkdownListLayoutMetrics.markerGap
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
            return
        }

        if line.hasPrefix("> ") {
            attributed.addAttributes([
                .foregroundColor: NSColor(Color.readingText.opacity(0.68))
            ], range: range)
            hideMarkup(prefixLength: rawLine.prefix { $0 == " " }.count + 2, lineRange: range, in: attributed)
        }
    }

    private static func applyInlineEmphasis(in attributed: NSMutableAttributedString) {
        let text = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)

        if let regex = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#) {
            regex.enumerateMatches(in: attributed.string, range: fullRange) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let contentRange = match.range(at: 1)
                attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .bold), range: contentRange)
                hide(range: NSRange(location: match.range.location, length: 2), in: attributed)
                hide(range: NSRange(location: NSMaxRange(match.range) - 2, length: 2), in: attributed)
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"`(.+?)`"#) {
            regex.enumerateMatches(in: attributed.string, range: fullRange) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let contentRange = match.range(at: 1)
                attributed.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                    .backgroundColor: NSColor.controlBackgroundColor
                ], range: contentRange)
                hide(range: NSRange(location: match.range.location, length: 1), in: attributed)
                hide(range: NSRange(location: NSMaxRange(match.range) - 1, length: 1), in: attributed)
            }
        }
    }

    private static func hideMarkup(prefixLength: Int, lineRange: NSRange, in attributed: NSMutableAttributedString) {
        guard prefixLength > 0 else { return }
        hide(range: NSRange(location: lineRange.location, length: min(prefixLength, lineRange.length)), in: attributed)
    }

    private static func bulletLayoutPrefixRange(in rawLine: String, lineRange: NSRange) -> NSRange? {
        let indentSpaces = rawLine.prefix { $0 == " " }.count
        let content = String(rawLine.dropFirst(indentSpaces))
        guard let bullet = content.first,
              MarkdownListNormalizer.isBullet(bullet),
              content.dropFirst().first == " " else { return nil }
        let prefixLength = min(indentSpaces + 2, lineRange.length)
        guard prefixLength > 0 else { return nil }
        return NSRange(location: lineRange.location, length: prefixLength)
    }

    private static func headingLayoutPrefixRange(
        in rawLine: String,
        lineRange: NSRange,
        markerCount: Int
    ) -> NSRange? {
        let indentSpaces = rawLine.prefix { $0 == " " }.count
        let prefixLength = min(indentSpaces + markerCount + 1, lineRange.length)
        guard prefixLength > 0 else { return nil }
        return NSRange(location: lineRange.location, length: prefixLength)
    }

    private static func hide(range: NSRange, in attributed: NSMutableAttributedString) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        attributed.addAttributes([
            .foregroundColor: NSColor.clear,
            .font: NSFont.systemFont(ofSize: 1)
        ], range: range)
    }

    private static func collapse(range: NSRange, in attributed: NSMutableAttributedString) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        attributed.addAttributes([
            .foregroundColor: NSColor.clear,
            .font: NSFont.systemFont(ofSize: 0.1)
        ], range: range)
    }
}
