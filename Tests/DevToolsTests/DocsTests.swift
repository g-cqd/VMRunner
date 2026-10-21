import Foundation
import Testing

@testable import DevTools

/// `vmr check docs` end to end on fixture trees: one passing tree and one failing tree per rule, plus this repository.
struct DocsTests {
    /// A tree that breaks exactly one rule: what changes, and the violation lines the checker must print (and no others).
    struct Case: CustomTestStringConvertible {
        let rule: String
        let files: [String: String]
        var removing: [String] = []
        let expected: [String]

        var testDescription: String { rule }
    }

    private func docs(_ files: [String: String], removing: [String] = [], environment: [String: String] = [:]) async throws -> Invocation {
        try await withTemporaryDirectory { directory in
            try write(files, to: directory)
            for path in removing {
                try FileManager.default.removeItem(at: directory.appending(path: path))
            }
            return try await VMR.vmr(["check", "docs", "--root", directory.path], in: directory, environment: environment)
        }
    }

    private static func violationLines(_ run: Invocation) -> [String] {
        run.error.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("error:") }
    }

    @Test
    func aTreeThatObeysTheLawPasses() async throws {
        let run = try await docs(DocsFixture.passing)
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.output.contains("docs: 9 file(s) checked, no violations"), "\(run.output)")
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  docs (") })
    }

    @Test(arguments: [
        Case(
            rule: "the white paper is missing", files: ["README.md": DocsFixture.document(["# Fixture"])],
            removing: ["docs/WHITE-PAPER.md"],
            expected: ["docs/WHITE-PAPER.md:1: the white paper is missing"]),
        Case(
            rule: "the white paper has more than 200 lines",
            files: ["docs/WHITE-PAPER.md": String(repeating: "line\n", count: 201)],
            expected: ["docs/WHITE-PAPER.md:201: the white paper has 201 lines, at most 200 allowed"]),
        Case(
            rule: "an ADR file name is not NNNN-kebab", files: ["docs/adr/first.md": DocsFixture.adr("0009")],
            expected: ["docs/adr/first.md:1: the file name must be NNNN-kebab-title.md"]),
        Case(
            rule: "two ADRs share a number", files: ["docs/adr/0001-second.md": DocsFixture.adr("0001")],
            expected: ["docs/adr/0001-second.md:1: ADR number 0001 is already used by 0001-first.md"]),
        Case(
            rule: "an ADR has no front matter", files: ["docs/adr/0001-first.md": DocsFixture.document(["# 0001 — Decision"])],
            expected: ["docs/adr/0001-first.md:1: front matter is missing (the file must start with ---)"]),
        Case(
            rule: "an ADR status is not allowed", files: ["docs/adr/0001-first.md": DocsFixture.adr("0001", status: "done")],
            expected: ["docs/adr/0001-first.md:2: status must be one of proposed, accepted, superseded, not 'done'"]),
        Case(
            rule: "an ADR date is not a date",
            files: ["docs/adr/0001-first.md": DocsFixture.adr("0001").replacingOccurrences(of: "2026-10-21", with: "2026-02-30")],
            expected: ["docs/adr/0001-first.md:3: date must be a real YYYY-MM-DD date, not '2026-02-30'"]),
        Case(
            rule: "an ADR H1 carries another number", files: ["docs/adr/0001-first.md": DocsFixture.adr("0007")],
            expected: ["docs/adr/0001-first.md:5: the H1 numbers the document 0007, the file name says 0001"]),
        Case(
            rule: "a superseded ADR has no banner",
            files: ["docs/adr/0002-old.md": DocsFixture.adr("0002", status: "superseded", extra: ["superseded-by: ADR-0003"])],
            expected: ["docs/adr/0002-old.md:6: a superseded ADR needs a banner line starting '> **Superseded by ADR-' after the H1"]),
        Case(
            rule: "a superseded ADR names no successor",
            files: ["docs/adr/0002-old.md": DocsFixture.adr("0002", status: "superseded", banner: true)],
            expected: ["docs/adr/0002-old.md:1: a superseded ADR needs superseded-by: ADR-NNNN"]),
        Case(
            rule: "a superseded ADR names a successor that does not exist",
            files: [
                "docs/adr/0002-old.md": DocsFixture.adr("0002", status: "superseded", extra: ["superseded-by: ADR-0009"], banner: true)
            ],
            expected: ["docs/adr/0002-old.md:4: superseded-by must name an existing ADR as ADR-NNNN, not 'ADR-0009'"]),
        Case(
            rule: "the successor does not point back", files: ["docs/adr/0003-new.md": DocsFixture.adr("0003")],
            expected: ["docs/adr/0003-new.md:1: supersedes must be ADR-0002, because 0002-old.md is superseded by it"]),
    ])
    func adrRules(_ failing: Case) async throws {
        try await expectViolations(failing)
    }

    @Test(arguments: [
        Case(
            rule: "two roadmap entries share a number", files: ["docs/roadmap/0001-second.md": DocsFixture.roadmap("0001")],
            expected: ["docs/roadmap/0001-second.md:1: roadmap entry number 0001 is already used by 0001-base.md"]),
        Case(
            rule: "a roadmap status is not allowed", files: ["docs/roadmap/0001-base.md": DocsFixture.roadmap("0001", status: "started")],
            expected: ["docs/roadmap/0001-base.md:2: status must be one of pending, in-progress, done, not 'started'"]),
        Case(
            rule: "a roadmap entry has no date",
            files: ["docs/roadmap/0001-base.md": DocsFixture.document(front: ["status: done"], ["# 0001 — Work"])],
            expected: ["docs/roadmap/0001-base.md:1: front matter has no date"]),
        Case(
            rule: "a roadmap H1 carries another number", files: ["docs/roadmap/0001-base.md": DocsFixture.roadmap("0004")],
            expected: ["docs/roadmap/0001-base.md:6: the H1 numbers the document 0004, the file name says 0001"]),
        Case(
            rule: "blocked-by names an entry that does not exist",
            files: ["docs/roadmap/0002-next.md": DocsFixture.roadmap("0002", blockedBy: "[\"0001\", \"0099\"]")],
            expected: ["docs/roadmap/0002-next.md:3: blocked-by names 0099, which is not a roadmap entry"]),
        Case(
            rule: "blocked-by names the entry itself",
            files: ["docs/roadmap/0002-next.md": DocsFixture.roadmap("0002", blockedBy: "[\"0002\"]")],
            expected: ["docs/roadmap/0002-next.md:3: blocked-by names the entry itself"]),
        Case(
            rule: "blocked-by is not a list", files: ["docs/roadmap/0002-next.md": DocsFixture.roadmap("0002", blockedBy: "0001")],
            expected: ["docs/roadmap/0002-next.md:3: blocked-by must be a list such as [\"0003\"]"]),
        Case(
            rule: "blocked-by forms a cycle",
            files: [
                "docs/roadmap/0001-base.md": DocsFixture.roadmap("0001", blockedBy: "[\"0002\"]"),
                "docs/roadmap/0002-next.md": DocsFixture.roadmap("0002", blockedBy: "[\"0001\"]"),
            ],
            expected: ["docs/roadmap/0002-next.md:3: blocked-by forms a cycle: 0001 -> 0002 -> 0001"]),
        Case(
            rule: "decision names an ADR that does not exist",
            files: ["docs/roadmap/0002-next.md": DocsFixture.roadmap("0002", extra: ["decision: ADR-0042"])],
            expected: ["docs/roadmap/0002-next.md:5: decision must name an existing ADR as ADR-NNNN, not 'ADR-0042'"]),
    ])
    func roadmapRules(_ failing: Case) async throws {
        try await expectViolations(failing)
    }

    @Test(arguments: [
        Case(
            rule: "a diary file name is not YYYY-MM-DD-NN", files: ["docs/diary/notes.md": DocsFixture.diary],
            expected: ["docs/diary/notes.md:1: the file name must be YYYY-MM-DD-NN.md with a real date"]),
        Case(
            rule: "a diary file has more than 256 lines",
            files: ["docs/diary/2026-10-21-01.md": DocsFixture.diary + String(repeating: "line\n", count: 254)],
            expected: ["docs/diary/2026-10-21-01.md:257: the diary has 257 lines, at most 256 allowed"]),
        Case(
            rule: "a diary H1 disagrees with the file name",
            files: ["docs/diary/2026-10-21-01.md": DocsFixture.diary.replacingOccurrences(of: "(1)", with: "(2)")],
            expected: ["docs/diary/2026-10-21-01.md:1: the H1 must be '# Diary — 2026-10-21 (1)' to match the file name"]),
    ])
    func diaryRules(_ failing: Case) async throws {
        try await expectViolations(failing)
    }

    @Test(arguments: [
        Case(
            rule: "a study file name has no month", files: ["docs/research/topic.md": DocsFixture.research()],
            expected: ["docs/research/topic.md:1: the file name must be topic-YYYY-MM.md"]),
        Case(
            rule: "a study has no front matter", files: ["docs/research/topic-name-2026-10.md": DocsFixture.document(["# Study"])],
            expected: ["docs/research/topic-name-2026-10.md:1: front matter is missing (the file must start with ---)"]),
        Case(
            rule: "a study's month disagrees with its date", files: ["docs/research/other-2026-09.md": DocsFixture.research()],
            expected: ["docs/research/other-2026-09.md:2: the date is in 2026-10, the file name says 2026-09"]),
        Case(
            rule: "a study has no question", files: ["docs/research/topic-name-2026-10.md": DocsFixture.research(question: nil)],
            expected: ["docs/research/topic-name-2026-10.md:1: front matter needs a non-empty question"]),
        Case(
            rule: "a study has no feeds", files: ["docs/research/topic-name-2026-10.md": DocsFixture.research(feeds: nil)],
            expected: ["docs/research/topic-name-2026-10.md:1: front matter has no feeds"]),
        Case(
            rule: "a study feeds a roadmap entry that does not exist",
            files: ["docs/research/topic-name-2026-10.md": DocsFixture.research(feeds: "[roadmap 0042]")],
            expected: ["docs/research/topic-name-2026-10.md:4: feeds names roadmap 0042, which is not a roadmap entry"]),
        Case(
            rule: "a study feeds an ADR that does not exist",
            files: ["docs/research/topic-name-2026-10.md": DocsFixture.research(feeds: "[ADR-0042]")],
            expected: ["docs/research/topic-name-2026-10.md:4: feeds names ADR-0042, which is not an ADR"]),
        Case(
            rule: "a study feeds something that is neither",
            files: ["docs/research/topic-name-2026-10.md": DocsFixture.research(feeds: "[issue 7]")],
            expected: ["docs/research/topic-name-2026-10.md:4: feeds item 'issue 7' must be 'roadmap NNNN' or 'ADR-NNNN'"]),
    ])
    func researchRules(_ failing: Case) async throws {
        try await expectViolations(failing)
    }

    @Test(arguments: [
        Case(
            rule: "the README links to a missing file",
            files: ["README.md": DocsFixture.document(["# Fixture", "", "[gone](docs/missing.md)"])],
            expected: ["README.md:3: broken link: docs/missing.md does not exist"]),
        Case(
            rule: "a document links to a missing file, anchor or not",
            files: ["docs/diary/2026-10-21-01.md": DocsFixture.diary + "[up](../adr/0009-nope.md#why) and [ok](../adr/0001-first.md#x)\n"],
            expected: ["docs/diary/2026-10-21-01.md:4: broken link: ../adr/0009-nope.md#why does not exist"]),
        Case(
            rule: "a reference definition points nowhere",
            files: ["docs/WHITE-PAPER.md": DocsFixture.document(["# White paper", "", "[ref]: nowhere.md"])],
            expected: ["docs/WHITE-PAPER.md:3: broken link: nowhere.md does not exist"]),
    ])
    func linkRules(_ failing: Case) async throws {
        try await expectViolations(failing)
    }

    @Test
    func everyViolationIsReportedWithACount() async throws {
        let run = try await docs(
            DocsFixture.variant([
                "docs/adr/0001-first.md": DocsFixture.adr("0001", status: "done"),
                "README.md": DocsFixture.document(["# Fixture", "", "[gone](docs/missing.md)"]),
            ]))
        #expect(run.status == 1)
        #expect(Self.violationLines(run).count == 2)
        #expect(run.error.contains("error: docs: 2 violation(s) in 9 file(s) checked"), "\(run.error)")
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  docs (") })
    }

    @Test
    func thisRepositorysOwnDocsObeyTheLaw() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let report = DocsChecker.check(root: root)
        #expect(report.violations.isEmpty, "\(report.violations.map(\.description).joined(separator: "\n"))")
        #expect(report.filesChecked > 40, "README.md, the white paper and every ADR, roadmap entry, diary and study were read")
    }

    // MARK: Pure pieces

    @Test
    func datesMustExist() {
        #expect(DocsDate("2024-02-29") != nil, "2024 is a leap year")
        #expect(DocsDate("2026-02-29") == nil)
        #expect(DocsDate("2026-13-01") == nil)
        #expect(DocsDate("2026-4-01") == nil)
        #expect(DocsDate("2026-10-21 ") == nil)
    }

    @Test
    func cyclesAreFoundOnceAndAcyclicGraphsHaveNone() {
        #expect(DocsChecker.cycles(in: ["a": ["b"], "b": ["c"], "c": ["a"]]) == [["a", "b", "c", "a"]])
        #expect(DocsChecker.cycles(in: ["a": ["b", "c"], "b": ["c"]]).isEmpty, "a diamond is not a cycle")
    }

    @Test(
        arguments: [
            ("https://example.com/a.md", nil), ("mailto:a@example.com", nil), ("#anchor", nil), ("", nil),
            ("a/b.md#c", "a/b.md"), ("a%20b.md?x=1", "a b.md"), ("<a/b.md>", "a/b.md"), ("/docs/x.md", "/docs/x.md"),
        ] as [(String, String?)])
    func onlyLocalLinkTargetsAreChecked(target: String, path: String?) {
        #expect(DocsChecker.localPath(of: target) == path)
    }

    @Test
    func frontMatterListsAreUnquoted() {
        let entry = FrontMatter.Entry(value: "[\"0001\", '0002', roadmap 0003 , ]", line: 1)
        #expect(FrontMatter.items(of: entry) == ["0001", "0002", "roadmap 0003"])
        #expect(FrontMatter.items(of: FrontMatter.Entry(value: "[]", line: 1))?.isEmpty == true)
        #expect(FrontMatter.items(of: FrontMatter.Entry(value: "0001", line: 1)) == nil)
    }

    // MARK: Helpers

    private func expectViolations(_ failing: Case) async throws {
        let run = try await docs(DocsFixture.variant(failing.files), removing: failing.removing)
        #expect(run.status == 1, "\(run.combined)")
        #expect(Self.violationLines(run) == failing.expected, "\(run.error)")
    }
}
