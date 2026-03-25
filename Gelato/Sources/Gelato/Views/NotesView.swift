import AppKit
import SwiftUI

/// Single-surface markdown notes editor with live structural styling.
struct NotesView: View {
    let sessionID: String
    let library: SessionLibrary

    @State private var text: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var isLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTextView(text: $text, placeholder: "Write notes...")
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .task {
            let loaded = await library.loadNotes(for: sessionID)
            text = loaded
            isLoaded = true
        }
        .onChange(of: text) {
            guard isLoaded else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await library.saveNotes(for: sessionID, text: text)
            }
        }
    }
}

private struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, placeholder: placeholder)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

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
            text = textView.string
            style(textView: textView)
        }

        @MainActor
        func applyText(_ string: String) {
            guard let textView else { return }
            isApplying = true
            textView.string = string
            style(textView: textView)
            isApplying = false
        }

        @MainActor
        private func style(textView: PlaceholderTextView) {
            let selectedRanges = textView.selectedRanges
            let text = textView.string
            let attributed = MarkdownStyler.makeAttributedString(text: text)

            textView.textStorage?.setAttributedString(attributed)
            textView.selectedRanges = selectedRanges
            textView.needsDisplay = true
        }
    }
}

private final class PlaceholderTextView: NSTextView {
    private enum ListMetrics {
        static let indentStep: CGFloat = 24
        static let markerGap: CGFloat = 10
        static let topLevelMarkerWidth: CGFloat = 12
        static let nestedMarkerWidth: CGFloat = 10
    }

    var placeholder: String = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawCustomBullets(in: dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
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
        guard let layoutManager, let textContainer else { return }

        let nsText = string as NSString
        var location = 0

        while location < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let rawLine = nsText.substring(with: lineRange)
            let trimmedLine = rawLine.trimmingCharacters(in: .newlines)
            let indentSpaces = rawLine.prefix { $0 == " " }.count
            let indentLevel = indentSpaces / 2

            if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

                if dirtyRect.intersects(lineRect) {
                    let origin = textContainerOrigin
                    let baseIndent = CGFloat(indentLevel) * ListMetrics.indentStep
                    let markerX = origin.x + baseIndent + 2
                    let markerY = origin.y + lineRect.minY + (lineRect.height / 2)
                    drawBullet(level: indentLevel, at: NSPoint(x: markerX, y: markerY))
                }
            }

            location = NSMaxRange(lineRange)
        }
    }

    private func drawBullet(level: Int, at point: NSPoint) {
        let color = NSColor.secondaryLabelColor

        if level == 0 {
            let rect = NSRect(x: point.x, y: point.y - 3.5, width: 7, height: 7)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: point.x + 1, y: point.y))
            path.line(to: NSPoint(x: point.x + 9, y: point.y))
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        }
    }
}

private enum MarkdownStyler {
    private enum ListMetrics {
        static let indentStep: CGFloat = 24
        static let markerGap: CGFloat = 10
        static let topLevelMarkerWidth: CGFloat = 12
        static let nestedMarkerWidth: CGFloat = 10
    }

    static func makeAttributedString(text: String) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let attributed = NSMutableAttributedString(string: text)

        attributed.addAttributes([
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.labelColor
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
        paragraph.firstLineHeadIndent = CGFloat(indentLevel) * ListMetrics.indentStep
        paragraph.headIndent = paragraph.firstLineHeadIndent

        attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)

        if line.hasPrefix("# ") {
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 18, weight: .bold)
            ], range: range)
            hideMarkup(prefixLength: rawLine.prefix { $0 == " " }.count + 2, lineRange: range, in: attributed)
            return
        }

        if line.hasPrefix("## ") {
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 16, weight: .bold)
            ], range: range)
            hideMarkup(prefixLength: rawLine.prefix { $0 == " " }.count + 3, lineRange: range, in: attributed)
            return
        }

        if line.hasPrefix("### ") {
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ], range: range)
            hideMarkup(prefixLength: rawLine.prefix { $0 == " " }.count + 4, lineRange: range, in: attributed)
            return
        }

        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let baseIndent = CGFloat(indentLevel) * ListMetrics.indentStep
            let markerWidth = indentLevel == 0 ? ListMetrics.topLevelMarkerWidth : ListMetrics.nestedMarkerWidth
            paragraph.firstLineHeadIndent = baseIndent + markerWidth + ListMetrics.markerGap
            paragraph.headIndent = paragraph.firstLineHeadIndent
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
            hideMarkup(prefixLength: rawLine.prefix { $0 == " " }.count + 2, lineRange: range, in: attributed)
            return
        }

        if let numberedPrefix = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let prefixWidth = CGFloat(line.distance(from: numberedPrefix.lowerBound, to: numberedPrefix.upperBound)) * 7
            let baseIndent = CGFloat(indentLevel) * ListMetrics.indentStep
            paragraph.firstLineHeadIndent = baseIndent + prefixWidth + 8
            paragraph.headIndent = baseIndent + prefixWidth + 8
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
            return
        }

        if line.hasPrefix("> ") {
            attributed.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor
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

    private static func hide(range: NSRange, in attributed: NSMutableAttributedString) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        attributed.addAttributes([
            .foregroundColor: NSColor.clear,
            .font: NSFont.systemFont(ofSize: 1)
        ], range: range)
    }
}
