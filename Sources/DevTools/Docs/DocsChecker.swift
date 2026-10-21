import Foundation
import RegexBuilder

/// Enforces the documentation law of `docs/WHITE-PAPER.md` section 5 over `docs/` and `README.md`: the shape of the
/// white paper, ADRs, roadmap entries, diary files and research studies, and that every relative link resolves.
///
/// The rules for each kind of document are in `DocsChecker+Rules.swift`; this file loads the files, checks the white
/// paper and the links, and runs the rest.
struct DocsChecker {
    struct Report {
        /// Sorted by path, then line.
        let violations: [DocsViolation]
        let filesChecked: Int
    }

    static let whitePaperPath = "docs/WHITE-PAPER.md"
    static let whitePaperLineLimit = 200
    static let diaryLineLimit = 256

    let root: URL
    let patterns = DocsPatterns()
    private(set) var files: [String: MarkdownFile] = [:]
    private(set) var violations: [DocsViolation] = []

    /// Checks `root` (the repository root). A missing `docs/` directory is itself a violation (no white paper).
    static func check(root: URL) -> Report {
        var checker = Self(root: root)
        checker.loadFiles()
        checker.checkWhitePaper()
        checker.checkRules()
        checker.checkLinks()
        return Report(violations: checker.violations.sorted(), filesChecked: checker.files.count)
    }

    mutating func report(_ path: String, _ line: Int, _ message: String) {
        violations.append(DocsViolation(path: path, line: line, message: message))
    }

    /// The files directly inside `directory` (a path relative to the root), by path.
    func files(in directory: String) -> [MarkdownFile] {
        files.values.filter { $0.directory == directory }.sorted { $0.path < $1.path }
    }

    // MARK: Loading

    private mutating func loadFiles() {
        var paths = ["README.md"]
        let below = (try? FileManager.default.subpathsOfDirectory(atPath: root.appending(path: "docs").path)) ?? []
        paths += below.filter { $0.hasSuffix(".md") }.map { "docs/\($0)" }
        for path in paths {
            let url = root.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                report(path, 1, "cannot be read as UTF-8 text")
                continue
            }
            files[path] = MarkdownFile(path: path, text: text)
        }
    }

    // MARK: White paper

    private mutating func checkWhitePaper() {
        guard let paper = files[Self.whitePaperPath] else {
            report(Self.whitePaperPath, 1, "the white paper is missing")
            return
        }
        if paper.lines.count > Self.whitePaperLineLimit {
            report(
                paper.path, Self.whitePaperLineLimit + 1,
                "the white paper has \(paper.lines.count) lines, at most \(Self.whitePaperLineLimit) allowed")
        }
    }

    // MARK: Links

    private mutating func checkLinks() {
        for file in files.values.sorted(by: { $0.path < $1.path }) {
            var inFence = false
            for index in file.bodyStart..<file.lines.count {
                let line = file.lines[index]
                let indentless = line.drop { $0 == " " }
                if indentless.hasPrefix("```") || indentless.hasPrefix("~~~") {
                    inFence.toggle()
                } else if !inFence {
                    checkLinks(inLine: line, number: index + 1, of: file)
                }
            }
        }
    }

    private mutating func checkLinks(inLine line: Substring, number: Int, of file: MarkdownFile) {
        // Links inside inline code are examples, not links.
        let prose = line.contains("`") ? String(line).replacing(patterns.codeSpan, with: "") : String(line)
        var targets = prose.matches(of: patterns.inlineTarget).map { String($0.output.1) }
        if let definition = prose.firstMatch(of: patterns.definitionTarget) { targets.append(String(definition.output.1)) }
        for target in targets {
            checkLink(target, in: file, line: number)
        }
    }

    private mutating func checkLink(_ target: String, in file: MarkdownFile, line: Int) {
        guard let path = Self.localPath(of: target) else { return }
        // A leading slash is relative to the repository root, as on GitHub.
        let rooted = path.hasPrefix("/")
        let base = rooted ? root : root.appending(path: file.directory, directoryHint: .isDirectory)
        let destination = base.appending(path: rooted ? String(path.dropFirst()) : path).standardizedFileURL
        if !FileManager.default.fileExists(atPath: destination.path) {
            report(file.path, line, "broken link: \(target) does not exist")
        }
    }

    /// The file-system part of a link target, or nil for what is not checked: a URL with a scheme (`https:`,
    /// `mailto:`, ...) and a pure `#anchor`. A query or anchor after the path is dropped.
    static func localPath(of target: String) -> String? {
        var text = target.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        if let end = text.firstIndex(where: { $0 == "#" || $0 == "?" }) { text = String(text[..<end]) }
        guard !text.isEmpty, !hasScheme(text) else { return nil }
        return text.removingPercentEncoding ?? text
    }

    /// Whether the text starts with `scheme:` (a letter, then letters, digits, `+`, `.` or `-`).
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), text.first?.isASCII == true, text.first?.isLetter == true else { return false }
        return text[..<colon].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
    }
}
