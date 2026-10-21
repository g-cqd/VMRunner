import Foundation

/// A repository root whose docs/ and README.md obey the documentation law, built from small helpers so a test can
/// replace one file and keep the line numbers of its expectation obvious.
enum DocsFixture {
    /// A file made of optional front matter lines and body lines. Front matter line `i` (0-based) is line `i + 2`.
    static func document(front: [String] = [], _ body: [String]) -> String {
        ((front.isEmpty ? [] : ["---"] + front + ["---"]) + body).joined(separator: "\n") + "\n"
    }

    static func adr(_ number: String, status: String = "accepted", extra: [String] = [], banner: Bool = false) -> String {
        document(
            front: ["status: \(status)", "date: 2026-10-21"] + extra,
            ["# \(number) — Decision \(number)", ""] + (banner ? ["> **Superseded by ADR-0003.** See below.", ""] : []) + ["## Context"]
        )
    }

    static func roadmap(_ number: String, status: String = "done", blockedBy: String = "[]", extra: [String] = []) -> String {
        document(
            front: ["status: \(status)", "blocked-by: \(blockedBy)", "date: 2026-10-21"] + extra,
            ["# \(number) — Work \(number)", "", "Text."]
        )
    }

    static func research(
        date: String = "2026-10-21",
        question: String? = "\"Why?\"",
        feeds: String? = "[roadmap 0001, ADR-0001]"
    ) -> String {
        document(
            front: ["date: \(date)"] + (question.map { ["question: \($0)"] } ?? []) + (feeds.map { ["feeds: \($0)"] } ?? []),
            ["# Study", "", "Text."]
        )
    }

    static let diary = document(["# Diary — 2026-10-21 (1)", "", "Text."])

    static let readme = document([
        "# Fixture",
        "",
        "[site](https://example.com/x.md) [mail](mailto:a@example.com) [top](#top) [paper](docs/WHITE-PAPER.md#rules)",
        "[folder](docs/adr/) [adr](docs/adr/0001-first.md \"title\") [rooted](/docs/roadmap/0001-base.md)",
        "Inline code is not a link: `[x](missing.md)`.",
        "",
        "```",
        "[fenced](missing.md)",
        "```",
        "",
        "[ref]: docs/research/topic-name-2026-10.md",
    ])

    /// Every kind of document, all valid: ADR 0002 is superseded by 0003, roadmap 0002 is blocked by 0001.
    static var passing: [String: String] {
        [
            "README.md": readme,
            "docs/WHITE-PAPER.md": document(["# White paper", "", "[ADR](adr/0001-first.md)"]),
            "docs/adr/0001-first.md": adr("0001"),
            "docs/adr/0002-old.md": adr("0002", status: "superseded", extra: ["superseded-by: ADR-0003"], banner: true),
            "docs/adr/0003-new.md": adr("0003", extra: ["supersedes: ADR-0002"]),
            "docs/roadmap/0001-base.md": roadmap("0001"),
            "docs/roadmap/0002-next.md": roadmap("0002", status: "in-progress", blockedBy: "[\"0001\"]", extra: ["decision: ADR-0001"]),
            "docs/diary/2026-10-21-01.md": diary,
            "docs/research/topic-name-2026-10.md": research(),
        ]
    }

    static func variant(_ replacements: [String: String]) -> [String: String] {
        passing.merging(replacements) { _, new in new }
    }
}
