import SwiftUI

// Markdown in what the helper and the notes models write: bullets, numbered
// lists, headings, quotes, code and paragraphs, with **bold**, *italic*,
// `code` and links inside a line. SwiftUI only styles the inline part of a
// Markdown string, so the blocks are laid out here. Every line stays its own
// line, as the helpers write them ("✓ goal" lists, a person's details).

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    /// `marker` is "•" or the item's number ("2.").
    case bullet(indent: Int, marker: String, text: String)
    case quote(String)
    case code(String)
    case rule
    case text(String)
    /// A blank line between paragraphs.
    case gap
}

enum Markdown {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var code: [String]?
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.isEmpty {
                if let last = blocks.last, last != .gap { blocks.append(.gap) }
                continue
            }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            blocks.append(block(line, indent: indent))
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        while blocks.last == .gap { blocks.removeLast() }
        return blocks
    }

    private static func block(_ line: String, indent: Int) -> MarkdownBlock {
        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
            return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
        }
        if line == "---" || line == "***" || line == "___" { return .rule }
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return .bullet(indent: indent, marker: "•", text: String(line.dropFirst(marker.count)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .bullet(indent: indent, marker: digits + ".", text: String(rest.dropFirst(2)))
            }
        }
        if line.hasPrefix("> ") { return .quote(String(line.dropFirst(2))) }
        return .text(line)
    }

    /// One line's **bold**, *italic*, `code` and links; plain text if it
    /// doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// All of it as one run of text, for a card shown closed with a line limit.
    static func flat(_ blocks: [MarkdownBlock]) -> AttributedString {
        var out = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { out += AttributedString("\n") }
            switch block {
            case .heading(_, let text):
                var heading = inline(text)
                heading.inlinePresentationIntent = .stronglyEmphasized
                out += heading
            case .bullet(let indent, let marker, let text):
                out += AttributedString(String(repeating: "  ", count: indent) + marker + " ") + inline(text)
            case .quote(let text), .text(let text):
                out += inline(text)
            case .code(let text):
                var code = AttributedString(text)
                code.inlinePresentationIntent = .code
                out += code
            case .rule, .gap:
                break
            }
        }
        return out
    }
}

/// Markdown laid out as blocks, or, with `lineLimit`, as one run of text cut
/// at that many lines. Takes its font and text selection from where it sits.
struct MarkdownText: View {
    var text: String
    var lineLimit: Int?

    var body: some View {
        let blocks = Markdown.parse(text)
        if let lineLimit {
            Text(Markdown.flat(blocks)).lineLimit(lineLimit).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in row(block) }
            }
        }
    }

    @ViewBuilder
    private func row(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(Markdown.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(Markdown.inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider().padding(.vertical, 2)
        case .text(let text):
            Text(Markdown.inline(text)).fixedSize(horizontal: false, vertical: true)
        case .gap:
            Color.clear.frame(height: 4)
        }
    }
}
