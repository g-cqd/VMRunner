import Foundation
import Testing

@testable import DevTools

/// `vmr check policy` against temporary git repositories whose `origin/main` is a ref made by hand.
struct PolicyTests {
    private static let baseFiles: [String: String] = [
        "Package.swift": "// swift-tools-version: 6.0\n",
        ".vmr.json": #"{ "coverage": { "minimum": 60 } }"#,
        ".arcleak-baseline.json": #"{ "fingerprints": [] }"#,
        ".dolly-baseline.json": #"{ "fingerprints": ["aaa"] }"#,
        ".deadwood-baseline.json": #"{ "fingerprints": ["ccc", "ddd"] }"#,
        ".swiftlint.yml": """
        strict: true
        excluded:
          - .build # generated
        opt_in_rules:
          - force_unwrapping
          - empty_count
        disabled_rules:
          - trailing_comma
        line_length:
          warning: 140
        """,
        ".gitattributes": "* text=auto eol=lf\n*.png binary\n*.sarif linguist-generated\n",
    ]

    private func git(_ arguments: [String], in root: URL) async throws {
        let run = try await VMR.run("git", arguments, in: root)
        guard run.status == 0 else { throw TestSetupError("git \(arguments.joined(separator: " ")) failed: \(run.combined)") }
    }

    /// A repository with the base files committed on `main`, `origin/main` pointing at that commit, and a branch checked out.
    private func makeRepository(in base: URL, withBaseRef: Bool = true) async throws -> URL {
        let root = base.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(Self.baseFiles, to: root)
        for command in [
            ["init", "-q", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.com"],
            ["config", "commit.gpgsign", "false"], ["add", "."], ["commit", "-q", "-m", "base"],
        ] {
            try await git(command, in: root)
        }
        if withBaseRef { try await git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: root) }
        try await git(["checkout", "-q", "-b", "change"], in: root)
        return root
    }

    /// Writes `files`, commits them with `message`, and runs `vmr check policy`.
    private func policy(
        _ files: [String: String] = [:],
        message: String = "change",
        environment: [String: String] = [:],
        withBaseRef: Bool = true
    ) async throws -> Invocation {
        try await withTemporaryDirectory { base in
            let root = try await makeRepository(in: base, withBaseRef: withBaseRef)
            try write(files, to: root)
            try await git(["add", "-A"], in: root)
            try await git(["commit", "-q", "--allow-empty", "-m", message], in: root)
            return try await VMR.vmr(["check", "policy"], in: root, environment: environment)
        }
    }

    @Test
    func anUnchangedBranchPasses() async throws {
        let run = try await policy()
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.output.contains("policy: nothing relaxed since "), "\(run.output)")
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  policy (") })
    }

    @Test
    func withoutAnOriginMainThereIsNothingToCompareAndTheStepSaysSo() async throws {
        let run = try await policy([".dolly-baseline.json": #"{ "fingerprints": ["aaa", "bbb"] }"#], withBaseRef: false)
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.output.contains("policy: no origin/main to compare with"), "\(run.output)")
    }

    @Test(
        arguments: [
            // A baseline that accepts a finding it did not before: grown, replaced, or newly created.
            ([".dolly-baseline.json": #"{ "fingerprints": ["aaa", "bbb"] }"#], ".dolly-baseline.json accepts 1 more finding(s)"),
            ([".deadwood-baseline.json": #"{ "fingerprints": ["ccc", "zzz"] }"#], ".deadwood-baseline.json accepts 1 more finding(s)"),
            ([".arcleak-baseline.json": #"{ "fingerprints": ["x", "y"] }"#], ".arcleak-baseline.json accepts 2 more finding(s)"),
            // The coverage ratchet: a lower floor, or no file (the default floor is lower than 60).
            ([".vmr.json": #"{ "coverage": { "minimum": 50 } }"#], ".vmr.json lowers the coverage floor from 60 to 50"),
            ([".vmr.json": "{}"], ".vmr.json lowers the coverage floor from 60 to 55"),
            // SwiftLint made weaker.
            ([".swiftlint.yml": "disabled_rules:\n  - trailing_comma\n  - force_cast\n"], ".swiftlint.yml disables the rule force_cast"),
            ([".swiftlint.yml": "disabled_rules: [trailing_comma, todo]\n"], ".swiftlint.yml disables the rule todo"),
            (
                [".swiftlint.yml": "opt_in_rules:\n  - force_unwrapping\ndisabled_rules:\n  - trailing_comma\n"],
                "drops the opt-in rule empty_count"
            ),
            (
                [
                    ".swiftlint.yml":
                        "excluded:\n  - .build\n  - Sources/Network\nopt_in_rules:\n  - force_unwrapping\n  - empty_count\n"
                        + "disabled_rules:\n  - trailing_comma\n"
                ], "excludes Sources/Network from linting"
            ),
            // A diff that hides what changed.
            ([".gitattributes": "* text=auto eol=lf\n*.png binary\n*.sarif linguist-generated\n*.swift -diff\n"], "adds '*.swift -diff'"),
            (
                [".gitattributes": "* text=auto eol=lf\n*.png binary\n*.sarif linguist-generated\nSources/** linguist-generated=true\n"],
                "adds 'Sources/** linguist-generated=true'"
            ),
            ([".gitattributes": "* text=auto eol=lf\n*.png binary\n*.sarif linguist-generated\n*.lock binary\n"], "adds '*.lock binary'"),
        ] as [([String: String], String)])
    func aRelaxationFailsAndNamesWhatItRelaxed(files: [String: String], message: String) async throws {
        let run = try await policy(files)
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.error.contains(message), "\(run.error)")
        #expect(run.error.contains("Policy-Ack: <reason>"), "the way out is named: \(run.error)")
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  policy (") })
    }

    @Test(
        arguments: [
            [".dolly-baseline.json": #"{ "fingerprints": [] }"#],
            [".vmr.json": #"{ "coverage": { "minimum": 70 } }"#],
            [".swiftlint.yml": "strict: true\nopt_in_rules:\n  - force_unwrapping\n  - empty_count\n  - first_where\ndisabled_rules:\n"],
            [".gitattributes": "* text=auto eol=lf\n*.png binary\n*.sarif linguist-generated\n*.txt text\n"],
        ] as [[String: String]])
    func tighteningOrUnrelatedChangesPass(files: [String: String]) async throws {
        let run = try await policy(files)
        #expect(run.status == 0, "\(run.combined)")
    }

    @Test
    func aPolicyAckTrailerInACommitTheBranchAddsAcknowledges() async throws {
        let relaxed = [".dolly-baseline.json": #"{ "fingerprints": ["aaa", "bbb"] }"#]
        let run = try await policy(relaxed, message: "Accept a clone\n\nPolicy-Ack: the clone is generated code, see the PR")
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.output.contains("policy: 1 relaxation(s) acknowledged: the clone is generated code, see the PR"), "\(run.output)")
        #expect(run.error.contains("accepts 1 more finding(s)"), "the relaxation is still listed")
    }

    @Test
    func theEnvironmentVariableAcknowledgesALocalRun() async throws {
        let relaxed = [".vmr.json": #"{ "coverage": { "minimum": 50 } }"#]
        let run = try await policy(relaxed, environment: ["VMR_POLICY_ACK": "measuring on a slow machine"])
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.output.contains("acknowledged: measuring on a slow machine"), "\(run.output)")
    }

    @Test(arguments: ["Policy-Ack:", "Policy-Ack:   ", "policy-ack: lower case is not the trailer", "Not-Policy-Ack: nope"])
    func anEmptyOrMisspelledAcknowledgementDoesNotCount(line: String) async throws {
        let relaxed = [".dolly-baseline.json": #"{ "fingerprints": ["aaa", "bbb"] }"#]
        let run = try await policy(relaxed, message: "Accept a clone\n\n\(line)", environment: ["VMR_POLICY_ACK": "  "])
        #expect(run.status == 1, "\(run.combined)")
    }

    @Test
    func theTrailerIsFoundInAnyLineOfAnyCommitMessage() {
        #expect(Policy.trailerReason(in: "subject\n\nbody\n\nPolicy-Ack: because\nSigned-off-by: A") == "because")
        #expect(Policy.trailerReason(in: "subject\n\nPolicy-Ack:\n") == nil)
        #expect(Policy.trailerReason(in: "") == nil)
    }

    @Test
    func yamlListsAreReadInBlockAndFlowForm() {
        let text = "rules:\n  - x # comment\n  - 'y'\n\n  # skipped\n  - z\nother:\n  - w\n"
        #expect(Policy.yamlList("rules", in: text) == ["x", "y", "z"])
        #expect(Policy.yamlList("other", in: text) == ["w"])
        #expect(Policy.yamlList("missing", in: text).isEmpty)
        #expect(Policy.yamlList("flow", in: "flow: [one, two]\n") == ["one", "two"])
    }
}
