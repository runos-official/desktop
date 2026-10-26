import Foundation

/*
 How a CLI sentence is put in front of a person, in places that cannot hold all of it.

 The contract is that the app never REWRITES a CLI error. It may SHOW it differently. A menu line
 and a small window cannot hold a paragraph, and cutting one off mid-sentence hid the part that
 said what to do (FCR 1730: the sign-in window showed "...usually timing rather than a broken
 cluster. R" and stopped before "Run `runos vpn connect` again").

 So the two places are separate. A MENU LINE shows a short summary and, when it is a summary, the
 menu also offers Show Details, which opens the whole text in a window that wraps and scrolls. A
 WINDOW shows the whole text, wrapped, selectable and scrollable, never clipped.
*/
enum ErrorPresentation {
    /// How many characters one menu line carries before it is a summary. Menu items do not wrap, and
    /// a long one widens the whole menu.
    static let menuLineLimit = 90

    struct Line: Equatable {
        /// What the menu line says.
        let text: String
        /// True when `text` is not all of it, so the person needs a way to see the rest.
        let isSummary: Bool
    }

    /*
     One short line for a menu.

     - Only the first non-empty line, because a menu item is one line.
     - Runs of whitespace and control characters collapse to single spaces.
     - Cut at a word boundary when one is near the limit; a single very long word (a path, a URL)
       has none, and is cut at the limit.
     - Never leaves a backtick open: "Run `runos vpn con…" reads as a half-quoted command.
     - A text that fits is returned untouched.
    */
    static func menuLine(_ full: String, limit: Int = menuLineLimit) -> Line {
        let lines = full.split(whereSeparator: \.isNewline)
            .map { collapsed(String($0)) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return Line(text: "", isSummary: false) }
        let moreLines = lines.count > 1
        guard first.count > limit else { return Line(text: first, isSummary: moreLines) }
        return Line(text: clip(first, to: limit), isSummary: true)
    }

    /// The whole text for a window: newlines normalised, control characters removed, nothing cut.
    static func fullText(_ full: String) -> String {
        let normalised = full
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let kept = normalised.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !isControl(scalar)
        }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A real control character (NUL, escape, the C1 range). NOT `CharacterSet.controlCharacters`,
    /// which also holds format characters such as the zero-width joiner that glues an emoji sequence
    /// together; stripping those turned one family emoji into three.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }

    private static func collapsed(_ text: String) -> String {
        let spaced = String(text.unicodeScalars.map { isControl($0) ? " " : Character($0) })
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        var head = String(text.prefix(limit - 1))
        // Prefer a word boundary if one falls in the last third; otherwise the word is long and is cut.
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= (limit - 1) * 2 / 3 {
            head = String(head[..<space])
        }
        if head.filter({ $0 == "`" }).count % 2 == 1, let tick = head.lastIndex(of: "`") {
            head = String(head[..<tick])
        }
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? String(text.prefix(limit - 1)) : trimmed) + "\u{2026}"
    }
}
