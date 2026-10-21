import Foundation
import RegexBuilder

/// The rules for ADRs, roadmap entries, diary files and research studies.
extension DocsChecker {
    /// A numbered document (`NNNN-kebab-title.md`) that passed the file-name and uniqueness checks.
    struct Numbered {
        let number: String
        let file: MarkdownFile
        let frontMatter: FrontMatter?
    }

    mutating func checkRules() {
        let adrs = numbered(in: "docs/adr", kind: "ADR")
        let roadmap = numbered(in: "docs/roadmap", kind: "roadmap entry")
        let adrNumbers = Set(adrs.map(\.number))
        let roadmapNumbers = Set(roadmap.map(\.number))
        let adrsByNumber = Dictionary(uniqueKeysWithValues: adrs.map { ($0.number, $0) })

        for adr in adrs {
            checkADR(adr, others: adrsByNumber)
        }
        checkRoadmap(roadmap, roadmapNumbers: roadmapNumbers, adrNumbers: adrNumbers)
        for file in files(in: "docs/diary") {
            checkDiary(file)
        }
        for file in files(in: "docs/research") {
            checkResearch(file, roadmapNumbers: roadmapNumbers, adrNumbers: adrNumbers)
        }
    }

    // MARK: Numbered documents

    /// The documents of `directory` that have a valid name, the first one for each number; reports the rest.
    private mutating func numbered(in directory: String, kind: String) -> [Numbered] {
        var seen: [String: String] = [:]
        var accepted: [Numbered] = []
        for file in files(in: directory) {
            guard let match = file.name.wholeMatch(of: patterns.numberedName) else {
                report(file.path, 1, "the file name must be NNNN-kebab-title.md")
                continue
            }
            let number = String(match.output.1)
            if let first = seen[number] {
                report(file.path, 1, "\(kind) number \(number) is already used by \(first)")
                continue
            }
            seen[number] = file.name
            accepted.append(Numbered(number: number, file: file, frontMatter: requireFrontMatter(file)))
        }
        return accepted
    }

    private mutating func requireFrontMatter(_ file: MarkdownFile) -> FrontMatter? {
        if file.frontMatter == nil { report(file.path, 1, "front matter is missing (the file must start with ---)") }
        return file.frontMatter
    }

    /// Reports a missing `key` or one whose value is not in `allowed`; returns the value when it is valid.
    @discardableResult
    private mutating func requireChoice(_ key: String, in allowed: [String], of document: Numbered) -> String? {
        guard let frontMatter = document.frontMatter else { return nil }
        guard let entry = frontMatter[key] else {
            report(document.file.path, 1, "front matter has no \(key)")
            return nil
        }
        guard allowed.contains(entry.value) else {
            report(document.file.path, entry.line, "\(key) must be one of \(allowed.joined(separator: ", ")), not '\(entry.value)'")
            return nil
        }
        return entry.value
    }

    /// Reports a missing or malformed `date`; returns it when valid.
    @discardableResult
    private mutating func requireDate(in frontMatter: FrontMatter?, of file: MarkdownFile) -> DocsDate? {
        guard let frontMatter else { return nil }
        guard let entry = frontMatter["date"] else {
            report(file.path, 1, "front matter has no date")
            return nil
        }
        guard let date = DocsDate(entry.value) else {
            report(file.path, entry.line, "date must be a real YYYY-MM-DD date, not '\(entry.value)'")
            return nil
        }
        return date
    }

    /// Checks that the first content line is `# NNNN — Title` with the file's number. Returns its index.
    @discardableResult
    private mutating func requireNumberedHeading(of document: Numbered) -> Int? {
        let file = document.file
        guard let heading = file.firstContentLine(from: file.bodyStart) else {
            report(file.path, 1, "the file has no H1")
            return nil
        }
        guard let match = heading.text.wholeMatch(of: patterns.numberedHeading) else {
            report(file.path, heading.number, "the H1 must be '# \(document.number) — Title'")
            return nil
        }
        if String(match.output.1) != document.number {
            report(file.path, heading.number, "the H1 numbers the document \(match.output.1), the file name says \(document.number)")
        }
        return heading.number - 1
    }

    // MARK: ADRs

    private mutating func checkADR(_ adr: Numbered, others: [String: Numbered]) {
        let file = adr.file
        let status = requireChoice("status", in: ["proposed", "accepted", "superseded"], of: adr)
        requireDate(in: adr.frontMatter, of: file)
        let heading = requireNumberedHeading(of: adr)
        guard status == "superseded", let frontMatter = adr.frontMatter else { return }

        if let heading, !file.lines[(heading + 1)...].contains(where: { $0.hasPrefix("> **Superseded by ADR-") }) {
            report(file.path, heading + 1, "a superseded ADR needs a banner line starting '> **Superseded by ADR-' after the H1")
        }
        guard let entry = frontMatter["superseded-by"] else {
            report(file.path, 1, "a superseded ADR needs superseded-by: ADR-NNNN")
            return
        }
        guard let reference = entry.value.wholeMatch(of: patterns.adrReference), let successor = others[String(reference.output.1)] else {
            report(file.path, entry.line, "superseded-by must name an existing ADR as ADR-NNNN, not '\(entry.value)'")
            return
        }
        let back = successor.frontMatter?["supersedes"]?.value
        if back != "ADR-\(adr.number)" {
            report(
                successor.file.path, successor.frontMatter?["supersedes"]?.line ?? 1,
                "supersedes must be ADR-\(adr.number), because \(file.name) is superseded by it")
        }
    }

    // MARK: Roadmap

    private mutating func checkRoadmap(_ entries: [Numbered], roadmapNumbers: Set<String>, adrNumbers: Set<String>) {
        var blockers: [String: [String]] = [:]
        var lines: [String: Int] = [:]
        for entry in entries {
            let file = entry.file
            requireChoice("status", in: ["pending", "in-progress", "done"], of: entry)
            requireDate(in: entry.frontMatter, of: file)
            requireNumberedHeading(of: entry)
            guard let frontMatter = entry.frontMatter else { continue }

            if let decision = frontMatter["decision"] {
                let number = decision.value.wholeMatch(of: patterns.adrReference).map { String($0.output.1) }
                if number.map(adrNumbers.contains) != true {
                    report(file.path, decision.line, "decision must name an existing ADR as ADR-NNNN, not '\(decision.value)'")
                }
            }
            guard let blocked = frontMatter["blocked-by"] else { continue }
            guard let items = FrontMatter.items(of: blocked) else {
                report(file.path, blocked.line, "blocked-by must be a list such as [\"0003\"]")
                continue
            }
            lines[entry.number] = blocked.line
            for item in items {
                if item == entry.number {
                    report(file.path, blocked.line, "blocked-by names the entry itself")
                } else if roadmapNumbers.contains(item) {
                    blockers[entry.number, default: []].append(item)
                } else {
                    report(file.path, blocked.line, "blocked-by names \(item), which is not a roadmap entry")
                }
            }
        }
        let paths = Dictionary(uniqueKeysWithValues: entries.map { ($0.number, $0.file.path) })
        for cycle in Self.cycles(in: blockers) {
            let closing = cycle[cycle.count - 2]
            report(paths[closing] ?? "", lines[closing] ?? 1, "blocked-by forms a cycle: \(cycle.joined(separator: " -> "))")
        }
    }

    /// Every back edge of `edges` as the path that closes the cycle, `[b, ..., a, b]` for the edge a -> b.
    static func cycles(in edges: [String: [String]]) -> [[String]] {
        var found: [[String]] = []
        var finished: Set<String> = []
        var path: [String] = []

        func visit(_ node: String) {
            path.append(node)
            for next in edges[node, default: []].sorted() {
                if let start = path.firstIndex(of: next) {
                    found.append(Array(path[start...]) + [next])
                } else if !finished.contains(next) {
                    visit(next)
                }
            }
            path.removeLast()
            finished.insert(node)
        }
        for node in edges.keys.sorted() where !finished.contains(node) {
            visit(node)
        }
        return found
    }

    // MARK: Diary

    private mutating func checkDiary(_ file: MarkdownFile) {
        guard let name = file.name.wholeMatch(of: patterns.diaryName), let date = DocsDate(year: name.1, month: name.2, day: name.3) else {
            report(file.path, 1, "the file name must be YYYY-MM-DD-NN.md with a real date")
            return
        }
        if file.lines.count > Self.diaryLineLimit {
            report(file.path, Self.diaryLineLimit + 1, "the diary has \(file.lines.count) lines, at most \(Self.diaryLineLimit) allowed")
        }
        let expected = "# Diary — \(date.description) (\(name.4))"
        guard let heading = file.firstContentLine(from: 0) else {
            report(file.path, 1, "the file has no H1")
            return
        }
        let parsed = heading.text.wholeMatch(of: patterns.diaryHeading)
        if parsed.map({ ($0.1, $0.2, $0.3, $0.4) == (name.1, name.2, name.3, name.4) }) != true {
            report(file.path, heading.number, "the H1 must be '\(expected)' to match the file name")
        }
    }

    // MARK: Research

    private static func yearMonth(_ year: Int, _ month: Int) -> String { "\(DocsDate.padded(year, 4))-\(DocsDate.padded(month, 2))" }

    private mutating func checkResearch(_ file: MarkdownFile, roadmapNumbers: Set<String>, adrNumbers: Set<String>) {
        guard let name = file.name.wholeMatch(of: patterns.researchName) else {
            report(file.path, 1, "the file name must be topic-YYYY-MM.md")
            return
        }
        guard let frontMatter = requireFrontMatter(file) else { return }
        if let date = requireDate(in: frontMatter, of: file), (date.year, date.month) != (name.1, name.2) {
            let line = frontMatter["date"]?.line ?? 1
            report(
                file.path, line,
                "the date is in \(Self.yearMonth(date.year, date.month)), the file name says \(Self.yearMonth(name.1, name.2))")
        }
        if frontMatter["question"].map({ FrontMatter.unquoted($0.value).isEmpty }) != false {
            report(file.path, frontMatter["question"]?.line ?? 1, "front matter needs a non-empty question")
        }
        guard let feeds = frontMatter["feeds"] else {
            report(file.path, 1, "front matter has no feeds")
            return
        }
        guard let items = FrontMatter.items(of: feeds) else {
            report(file.path, feeds.line, "feeds must be a list such as [roadmap 0003, ADR-0002]")
            return
        }
        for item in items {
            if let reference = item.wholeMatch(of: patterns.roadmapReference) {
                if !roadmapNumbers.contains(String(reference.output.1)) {
                    report(file.path, feeds.line, "feeds names \(item), which is not a roadmap entry")
                }
            } else if let reference = item.wholeMatch(of: patterns.adrReference) {
                if !adrNumbers.contains(String(reference.output.1)) {
                    report(file.path, feeds.line, "feeds names \(item), which is not an ADR")
                }
            } else {
                report(file.path, feeds.line, "feeds item '\(item)' must be 'roadmap NNNN' or 'ADR-NNNN'")
            }
        }
    }
}
