import AppKit
import SwiftUI

/// Line-based YAML colouring for display. Not a parser: it recognises what a
/// Fleet manifest uses (keys, list dashes, scalars, quoted strings, comments,
/// block-scalar markers) and leaves anything else as plain text, so odd input
/// degrades to uncoloured rather than wrong.
enum YAMLHighlighter {
    struct Palette {
        var key = Color(nsColor: .systemBlue)
        var string = Color(nsColor: .systemGreen)
        var number = Color(nsColor: .systemOrange)
        var keyword = Color(nsColor: .systemPink)
        var comment = Color(nsColor: .secondaryLabelColor)
        var punctuation = Color(nsColor: .tertiaryLabelColor)
        var plain = Color(nsColor: .labelColor)
    }

    static func highlight(_ yaml: String, palette: Palette = Palette()) -> AttributedString {
        var out = AttributedString()
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            out += highlightLine(String(line), palette)
            if i < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }

    private static func piece(_ s: String, _ color: Color, italic: Bool = false) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = color
        if italic { a.font = .system(.callout, design: .monospaced).italic() }
        return a
    }

    private static func highlightLine(_ line: String, _ p: Palette) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(line)

        // Indentation.
        let indent = rest.prefix { $0 == " " }
        out += AttributedString(String(indent))
        rest = rest.dropFirst(indent.count)

        // Whole-line comment.
        if rest.hasPrefix("#") {
            return out + piece(String(rest), p.comment, italic: true)
        }

        // List dashes ("- ", possibly nested "- - ").
        while rest.hasPrefix("- ") || rest == "-" {
            out += piece("-", p.punctuation)
            rest = rest.dropFirst()
            let sp = rest.prefix { $0 == " " }
            out += AttributedString(String(sp))
            rest = rest.dropFirst(sp.count)
        }

        // Split off a trailing comment (" #" outside quotes).
        let (body, comment) = splitComment(rest)

        // key: value
        if let colon = keyColon(in: body) {
            let key = body[body.startIndex..<colon]
            out += piece(String(key), p.key)
            out += piece(":", p.punctuation)
            let after = body[body.index(after: colon)...]
            let sp = after.prefix { $0 == " " }
            out += AttributedString(String(sp))
            out += scalar(after.dropFirst(sp.count), p)
        } else {
            out += scalar(body, p)
        }

        if let comment {
            out += piece(String(comment), p.comment, italic: true)
        }
        return out
    }

    /// The colon ending a mapping key, if the text starts with one: an unquoted
    /// run (or a quoted string) followed by ":" and then a space or the end.
    private static func keyColon(in s: Substring) -> Substring.Index? {
        guard let first = s.first, first != "[", first != "{" else { return nil }
        var i = s.startIndex
        if first == "\"" || first == "'" {
            guard let close = s[s.index(after: i)...].firstIndex(of: first) else { return nil }
            i = s.index(after: close)
            guard i < s.endIndex, s[i] == ":" else { return nil }
            return i
        }
        while i < s.endIndex {
            if s[i] == ":" {
                let next = s.index(after: i)
                if next == s.endIndex || s[next] == " " { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func splitComment(_ s: Substring) -> (Substring, Substring?) {
        var quote: Character?
        var prev: Character = " "
        for i in s.indices {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" && prev == " " {
                // Keep the space before "#" with the body so alignment holds.
                return (s[s.startIndex..<i], s[i...])
            }
            prev = c
        }
        return (s, nil)
    }

    private static func scalar(_ s: Substring, _ p: Palette) -> AttributedString {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return AttributedString(String(s)) }
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") { return piece(String(s), p.string) }
        if ["|", ">", "|-", ">-", "|+", ">+"].contains(trimmed) { return piece(String(s), p.punctuation) }
        if ["true", "false", "null", "~", "yes", "no"].contains(trimmed.lowercased()) {
            return piece(String(s), p.keyword)
        }
        if Double(trimmed) != nil { return piece(String(s), p.number) }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { return piece(String(s), p.plain) }
        return piece(String(s), p.string)
    }
}

/// A read-only, selectable, syntax-coloured YAML block with Copy and Save.
struct YAMLBlockView: View {
    let yaml: String
    var fileName: String = "fleet.yaml"
    var maxHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(yaml, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    save()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
            }
            .controlSize(.small)
            ScrollView([.vertical, .horizontal]) {
                Text(YAMLHighlighter.highlight(yaml))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: maxHeight)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.init(filenameExtension: "yaml") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? yaml.write(to: url, atomically: true, encoding: .utf8)
    }
}
