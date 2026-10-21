import Foundation
import RegexBuilder

/// One broken documentation rule: `path:line: message`, with the path relative to the repository root.
struct DocsViolation: Equatable, Comparable, CustomStringConvertible {
    let path: String
    let line: Int
    let message: String

    var description: String { "\(path):\(line): \(message)" }

    static func < (left: Self, right: Self) -> Bool {
        (left.path, left.line, left.message) < (right.path, right.line, right.message)
    }
}

/// The `key: value` lines between the opening `---` on line 1 and the next `---`.
struct FrontMatter {
    struct Entry {
        let value: String
        /// 1-based.
        let line: Int
    }

    let entries: [String: Entry]
    /// Index in `MarkdownFile.lines` of the first line after the closing `---`.
    let bodyStart: Int

    subscript(key: String) -> Entry? { entries[key] }

    /// The items of an inline list (`[a, "b"]`), unquoted. Nil when the value is not a list.
    static func items(of entry: Entry) -> [String]? {
        let value = entry.value
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        return value.dropFirst().dropLast()
            .split(separator: ",")
            .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return text }
        return String(text.dropFirst().dropLast())
    }
}

/// A Markdown file read for the documentation checks.
struct MarkdownFile {
    let path: String
    let lines: [Substring]
    /// Nil when the file does not start with `---` or the front matter is never closed.
    let frontMatter: FrontMatter?

    /// Where the content starts: after the front matter, or at the first line.
    var bodyStart: Int { frontMatter?.bodyStart ?? 0 }

    var directory: String { (path as NSString).deletingLastPathComponent }
    var name: String { (path as NSString).lastPathComponent }

    init(path: String, text: String) {
        self.path = path
        // `isNewline` splits CRLF too (it is a single Character). A final newline does not start another line.
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        self.lines = lines
        frontMatter = Self.parseFrontMatter(lines)
    }

    /// 1-based number and text of the first non-blank line at or after `start`.
    func firstContentLine(from start: Int) -> (number: Int, text: Substring)? {
        guard let index = lines[start...].firstIndex(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        return (index + 1, lines[index])
    }

    private static func parseFrontMatter(_ lines: [Substring]) -> FrontMatter? {
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var entries: [String: FrontMatter.Entry] = [:]
        for index in 1..<close {
            guard let colon = lines[index].firstIndex(of: ":") else { continue }
            let key = lines[index][..<colon].trimmingCharacters(in: .whitespaces)
            let value = lines[index][lines[index].index(after: colon)...].trimmingCharacters(in: .whitespaces)
            entries[key] = FrontMatter.Entry(value: value, line: index + 1)
        }
        return FrontMatter(entries: entries, bodyStart: close + 1)
    }
}

/// A calendar date as the documents write it: `YYYY-MM-DD`.
struct DocsDate: Equatable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    /// Nil unless the text is exactly a real date.
    init?(_ text: String) {
        guard let match = text.wholeMatch(of: DocsPatterns().date) else { return nil }
        self.init(year: match.output.1, month: match.output.2, day: match.output.3)
    }

    init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), (1...Self.daysIn(month: month, year: year)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    var description: String { "\(Self.padded(year, 4))-\(Self.padded(month, 2))-\(Self.padded(day, 2))" }

    /// The number with leading zeros up to `width` digits.
    static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        let leap = (year.isMultiple(of: 4) && !year.isMultiple(of: 100)) || year.isMultiple(of: 400)
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }
}
