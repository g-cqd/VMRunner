// The provisioning library has no caller outside its tests until a later change attaches the seed to a machine, so a
// declaration only the tests reach is expected here; every other dead-code rule still applies.
// @dw:disable referenced-only-by-tests

/// A value of a spec document and the 1-based line it starts on. Every scalar is text: the reader never guesses a type, so
/// `no`, `1.10` and `null` stay the words they are, and the spec's model decides what each field means.
enum SpecNode: Equatable, Sendable {
    case text(String, line: Int)
    case list([Self], line: Int)
    case map([SpecEntry], line: Int)

    var line: Int {
        switch self {
        case .text(_, let line), .list(_, let line), .map(_, let line): line
        }
    }
}

/// One `key: value` of a map, in the order the document gives it.
struct SpecEntry: Equatable, Sendable {
    let key: String
    let line: Int
    let value: SpecNode
}

/// Reads a spec written in a strict subset of YAML, and refuses anything else with the line of the first problem.
///
/// Accepted: block maps (`key: value`, a key of ASCII letters, digits, `_`, `.` and `-`, once per map); block lists
/// (`- item`, indented under their key or at its column); plain, single-quoted and double-quoted scalars on one line
/// (double quotes take only `\\`, `\"`, `\n` and `\t`); literal blocks `|` and `|-`, whose text may hold tabs; comments on
/// a line of their own or after a space. Refused: a tab anywhere else, a carriage return, a byte order mark, `---` and
/// `...`, directives (`%`), anchors (`&`), aliases (`*`), tags (`!`), flow collections (`{ }`, `[ ]`), folded (`>`) and keep
/// (`|+`) blocks and indentation indicators, a plain value holding `: `, a value continued on the next line, a key without
/// a value, a key given twice in one map, and a line indented where nothing can start.
struct SpecReader {
    private struct Line {
        let number: Int
        var indent: Int
        var content: Substring
        let raw: Substring
    }

    private var lines: [Line]
    private var index = 0
    private let limits: ProvisioningLimits

    private init(_ text: String, limits: ProvisioningLimits) {
        self.limits = limits
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { offset, raw in
            let indent = raw.prefix { $0 == " " }.count
            return Line(number: offset + 1, indent: indent, content: raw.dropFirst(indent), raw: raw)
        }
    }

    /// The spec as a tree, or the first reason to refuse it. The root is always a map.
    static func read(_ text: String, limits: ProvisioningLimits = .standard) throws -> SpecNode {
        let size = text.utf8.count
        guard size <= limits.maxSpecBytes else {
            throw ProvisioningError(line: nil, "the spec is \(size) bytes; the limit is \(limits.maxSpecBytes)")
        }
        if let position = text.unicodeScalars.firstIndex(where: { $0 == "\r" || $0 == "\u{FEFF}" }) {
            let line = text.unicodeScalars[..<position].count(where: { $0 == "\n" }) + 1
            throw ProvisioningError(line: line, "a carriage return or a byte order mark: save the spec as UTF-8 with LF line endings")
        }
        var reader = Self(text, limits: limits)
        return try reader.document()
    }

    private mutating func document() throws -> SpecNode {
        guard let first = try significantLine() else { throw ProvisioningError(line: nil, "the spec is empty") }
        guard first.indent == 0 else { throw ProvisioningError(line: first.number, "the first line must not be indented") }
        guard !Self.isListItem(first.content) else {
            throw ProvisioningError(line: first.number, "a spec is a map of keys, not a list")
        }
        let root = try map(indent: 0, depth: 1)
        if let extra = try significantLine() {
            throw ProvisioningError(line: extra.number, "unexpected line: check its indentation")
        }
        return root
    }

    /// The next line that is not blank and not a comment, left unconsumed. Refuses tabs, document markers and directives.
    private mutating func significantLine() throws -> Line? {
        while index < lines.count {
            let line = lines[index]
            if line.raw.contains("\t") {
                throw ProvisioningError(line: line.number, "a tab character: indent with spaces (only a | block's text may hold tabs)")
            }
            if line.content.isEmpty || line.content.hasPrefix("#") {
                index += 1
                continue
            }
            if line.indent == 0, line.content == "---" || line.content.hasPrefix("--- ") || line.content == "..." {
                throw ProvisioningError(line: line.number, "one document only: --- and ... are not supported")
            }
            if line.content.hasPrefix("%") {
                throw ProvisioningError(line: line.number, "directives (%) are not supported")
            }
            return line
        }
        return nil
    }

    private func checkDepth(_ depth: Int) throws {
        guard depth <= limits.maxDepth else {
            throw ProvisioningError(line: lines[index].number, "nested deeper than \(limits.maxDepth) levels")
        }
    }

    private mutating func refuseDeeperLine(than indent: Int) throws {
        if let line = try significantLine(), line.indent > indent {
            throw ProvisioningError(line: line.number, "unexpected indentation")
        }
    }

    private mutating func map(indent: Int, depth: Int) throws -> SpecNode {
        try checkDepth(depth)
        var entries: [SpecEntry] = []
        var start: Int?
        while let line = try significantLine(), line.indent == indent, !Self.isListItem(line.content) {
            guard let entry = Self.entry(line.content) else {
                throw ProvisioningError(line: line.number, "expected key: value")
            }
            guard !entries.contains(where: { $0.key == entry.key }) else {
                throw ProvisioningError(line: line.number, "the key \(entry.key) appears twice in this map")
            }
            start = start ?? line.number
            index += 1
            let node = try valueNode(entry.rest, indent: indent, line: line.number, depth: depth, sharesColumn: true)
            entries.append(SpecEntry(key: entry.key, line: line.number, value: node))
        }
        try refuseDeeperLine(than: indent)
        return .map(entries, line: start ?? 0)
    }

    private mutating func list(indent: Int, depth: Int) throws -> SpecNode {
        try checkDepth(depth)
        var items: [SpecNode] = []
        var start: Int?
        while let line = try significantLine(), line.indent == indent, Self.isListItem(line.content) {
            start = start ?? line.number
            let afterDash = line.content.dropFirst()
            let gap = afterDash.prefix { $0 == " " }.count
            let item = afterDash.dropFirst(gap)
            if Self.entry(item) != nil {
                // `- key: value` starts a map whose keys line up with this first key: read the line as that key's line.
                lines[index].indent = indent + 1 + gap
                lines[index].content = item
                items.append(try map(indent: indent + 1 + gap, depth: depth + 1))
            } else {
                index += 1
                items.append(try valueNode(item, indent: indent, line: line.number, depth: depth, sharesColumn: false))
            }
        }
        try refuseDeeperLine(than: indent)
        return .list(items, line: start ?? 0)
    }

    /// The value after `key:` or `- `: text on the same line, a `|` block, or the map or list indented below. A list may
    /// start at its key's column (`sharesColumn`), never at a list item's.
    private mutating func valueNode(
        _ rest: Substring, indent: Int, line: Int, depth: Int, sharesColumn: Bool
    ) throws -> SpecNode {
        let text = rest.drop { $0 == " " }
        if text.hasPrefix("|") { return try literalBlock(text, indent: indent, line: line) }
        if !text.isEmpty, !text.hasPrefix("#") { return .text(try Self.scalar(text, line: line), line: line) }
        guard let next = try significantLine() else { throw ProvisioningError(line: line, "a value is missing") }
        let listAtColumn = sharesColumn && next.indent == indent && Self.isListItem(next.content)
        guard next.indent > indent || listAtColumn else { throw ProvisioningError(line: line, "a value is missing") }
        if Self.isListItem(next.content) { return try list(indent: next.indent, depth: depth + 1) }
        return try map(indent: next.indent, depth: depth + 1)
    }

    /// A `|` or `|-` block: the lines indented deeper than its key, the first of them setting the indentation, ending with
    /// one newline (`|`) or none (`|-`). Blank lines inside are kept; blank lines at the end are dropped.
    private mutating func literalBlock(_ header: Substring, indent: Int, line: Int) throws -> SpecNode {
        var indicator = header.dropFirst()
        let strips = indicator.first == "-"
        if strips { indicator = indicator.dropFirst() }
        let after = indicator.drop { $0 == " " }
        guard after.isEmpty || (after.hasPrefix("#") && after.count < indicator.count) else {
            throw ProvisioningError(line: line, "only | and |- are supported, without an indentation or keep indicator")
        }
        var body: [Substring] = []
        var bodyIndent: Int?
        while index < lines.count {
            let candidate = lines[index]
            if !candidate.content.isEmpty {
                guard candidate.indent > indent, candidate.indent >= bodyIndent ?? 0 else { break }
                bodyIndent = bodyIndent ?? candidate.indent
            }
            body.append(candidate.content.isEmpty ? "" : candidate.raw.dropFirst(bodyIndent ?? 0))
            index += 1
        }
        while let last = body.last, last.isEmpty { body.removeLast() }
        guard !body.isEmpty else { throw ProvisioningError(line: line, "a | block needs at least one line of text") }
        return .text(body.joined(separator: "\n") + (strips ? "" : "\n"), line: line)
    }

    /// `key: rest` or `key:`, the key made of ASCII letters, digits, `_`, `.` and `-`; nil for anything else.
    private static func entry(_ content: Substring) -> (key: String, rest: Substring)? {
        let key = content.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") }
        let afterKey = content.dropFirst(key.count)
        guard !key.isEmpty, afterKey.first == ":" else { return nil }
        let rest = afterKey.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (String(key), rest)
    }

    private static func isListItem(_ content: Substring) -> Bool {
        content == "-" || content.hasPrefix("- ")
    }

    /// A value on one line: double-quoted, single-quoted or plain, a comment after it dropped.
    private static func scalar(_ text: Substring, line: Int) throws -> String {
        guard let first = text.first else { return "" }
        switch first {
        case "\"": return try doubleQuoted(text.dropFirst(), line: line)
        case "'": return try singleQuoted(text.dropFirst(), line: line)
        case "&": throw ProvisioningError(line: line, "anchors (&) are not supported")
        case "*": throw ProvisioningError(line: line, "aliases (*) are not supported")
        case "!": throw ProvisioningError(line: line, "tags (!) are not supported")
        case "{", "[": throw ProvisioningError(line: line, "flow collections ({ } and [ ]) are not supported: use the block form")
        case ">": throw ProvisioningError(line: line, "folded blocks (>) are not supported: use |")
        case "%", "@", "`", ",", "?", ":", "]", "}":
            throw ProvisioningError(line: line, "a plain value cannot start with \(first): quote it")
        case "-" where text.count == 1 || text.dropFirst().first == " ":
            throw ProvisioningError(line: line, "a list starts on a line of its own")
        default: return try plain(text, line: line)
        }
    }

    private static func plain(_ text: Substring, line: Int) throws -> String {
        var value = text
        if let comment = value.firstRange(of: " #") { value = value[..<comment.lowerBound] }
        while value.last == " " { value = value.dropLast() }
        guard !value.contains(": "), !value.hasSuffix(":") else {
            throw ProvisioningError(line: line, "a plain value cannot hold \": \" or end with \":\": quote it")
        }
        return String(value)
    }

    private static let escapes: [Character: Character] = ["\\": "\\", "\"": "\"", "n": "\n", "t": "\t"]

    /// The text of a double-quoted value, from just after its opening quote.
    private static func doubleQuoted(_ text: Substring, line: Int) throws -> String {
        var result = ""
        var rest = text
        while let character = rest.popFirst() {
            switch character {
            case "\"":
                try requireNothingAfterQuote(rest, line: line)
                return result
            case "\\":
                guard let escaped = rest.popFirst(), let replacement = escapes[escaped] else {
                    throw ProvisioningError(line: line, "only \\\\, \\\", \\n and \\t are supported inside double quotes")
                }
                result.append(replacement)
            default:
                result.append(character)
            }
        }
        throw ProvisioningError(line: line, "a quoted value must end on its line")
    }

    /// The text of a single-quoted value, from just after its opening quote; `''` stands for one quote.
    private static func singleQuoted(_ text: Substring, line: Int) throws -> String {
        var result = ""
        var rest = text
        while let character = rest.popFirst() {
            guard character == "'" else {
                result.append(character)
                continue
            }
            guard rest.first == "'" else {
                try requireNothingAfterQuote(rest, line: line)
                return result
            }
            result.append("'")
            rest = rest.dropFirst()
        }
        throw ProvisioningError(line: line, "a quoted value must end on its line")
    }

    private static func requireNothingAfterQuote(_ rest: Substring, line: Int) throws {
        let after = rest.drop { $0 == " " }
        guard after.isEmpty || (after.hasPrefix("#") && after.count < rest.count) else {
            throw ProvisioningError(line: line, "unexpected text after a quoted value")
        }
    }
}
