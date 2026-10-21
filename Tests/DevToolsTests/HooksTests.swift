import Foundation
import Testing

/// `vmr hooks install` and the pre-commit hook it installs, driven through real `git commit` in a temporary repository.
struct HooksTests {
    private static let formatted = "func add(_ left: Int, _ right: Int) -> Int {\n  left + right\n}\n"
    private static let badlyFormatted = "func add(_ left:Int,_ right:Int)->Int{return left+right}\n"
    private static let forceUnwrap =
        formatted + "func first(_ values: [Int]) -> Int {\n  let first: Int? = values.first\n  return first!\n}\n"
    private static let swiftlintConfig = "strict: true\nonly_rules:\n  - force_unwrapping\n"

    private func git(_ arguments: [String], in repository: URL) async throws -> Invocation {
        try await VMR.run("git", arguments, in: repository)
    }

    /// An initialized repository with a local identity, signing off, and the installed hook.
    private func makeRepository(in base: URL, install: Bool = true) async throws -> URL {
        let repository = base.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try write([".swiftlint.yml": Self.swiftlintConfig], to: repository)
        for command in [
            ["init", "-q", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.com"],
            ["config", "commit.gpgsign", "false"], ["config", "tag.gpgsign", "false"],
        ] {
            let run = try await git(command, in: repository)
            #expect(run.status == 0, "\(run.combined)")
        }
        if install {
            let run = try await VMR.vmr(["hooks", "install"], in: repository)
            #expect(run.status == 0, "\(run.combined)")
        }
        return repository
    }

    private func commitCount(in repository: URL) async throws -> Int {
        let run = try await git(["rev-list", "--count", "--all"], in: repository)
        return Int(run.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    @Test
    func installLinksTheHookToTheVmrBinary() async throws {
        try await withTemporaryDirectory { base in
            let repository = try await makeRepository(in: base, install: false)
            let run = try await VMR.vmr(["hooks", "install"], in: repository)
            #expect(run.status == 0, "\(run.combined)")
            let hook = repository.appending(path: ".git/hooks/pre-commit")
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: hook.path)
            #expect(target == (try VMR.binary(named: "vmr")).path)
            #expect(FileManager.default.isExecutableFile(atPath: hook.path))
            #expect(run.output.contains("git hook installed:"))

            let again = try await VMR.vmr(["hooks", "install"], in: repository)
            #expect(again.status == 0, "installing twice is fine: \(again.combined)")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func aStagedFormatViolationBlocksTheCommit() async throws {
        try await withTemporaryDirectory { base in
            let repository = try await makeRepository(in: base)
            try write(["Sources/Bad.swift": Self.badlyFormatted], to: repository)
            _ = try await git(["add", "Sources/Bad.swift"], in: repository)
            let commit = try await git(["commit", "-q", "-m", "bad"], in: repository)
            #expect(commit.status != 0, "\(commit.combined)")
            #expect(
                commit.error.contains("pre-commit: swift-format lint (1 file(s))")
                    || commit.output.contains("pre-commit: swift-format lint (1 file(s))"))
            #expect(commit.combined.contains("Bad.swift"), "the finding names the file: \(commit.combined)")
            #expect(commit.error.contains("pre-commit: checks failed; fix the findings above"), "\(commit.error)")
            #expect(try await commitCount(in: repository) == 0, "no commit was created")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func aStagedSwiftLintViolationBlocksTheCommit() async throws {
        try await withTemporaryDirectory { base in
            let repository = try await makeRepository(in: base)
            try write(["Sources/Unwrap.swift": Self.forceUnwrap], to: repository)
            _ = try await git(["add", "Sources/Unwrap.swift"], in: repository)
            let commit = try await git(["commit", "-q", "-m", "unwrap"], in: repository)
            #expect(commit.status != 0, "\(commit.combined)")
            #expect(commit.combined.contains("force_unwrapping"), "\(commit.combined)")
            #expect(try await commitCount(in: repository) == 0)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func cleanStagedFilesCommitAndUnstagedViolationsAreIgnored() async throws {
        try await withTemporaryDirectory { base in
            let repository = try await makeRepository(in: base)
            // A violating file that is on disk but never staged, and a staged clean one.
            try write(
                ["Sources/Unstaged.swift": Self.badlyFormatted, "Sources/Good.swift": Self.formatted, "README.md": "# not Swift\n"],
                to: repository)
            _ = try await git(["add", "Sources/Good.swift", "README.md"], in: repository)
            let commit = try await git(["commit", "-q", "-m", "good"], in: repository)
            #expect(commit.status == 0, "\(commit.combined)")
            #expect(try await commitCount(in: repository) == 1)

            // Only non-Swift files staged: the hook has nothing to check.
            try write(["NOTES.md": "notes\n"], to: repository)
            _ = try await git(["add", "NOTES.md"], in: repository)
            let notes = try await git(["commit", "-q", "-m", "notes"], in: repository)
            #expect(notes.status == 0, "\(notes.combined)")
        }
    }

    @Test
    func theHookCanBeRunByHandAndBypassedWithNoVerify() async throws {
        try await withTemporaryDirectory { base in
            let repository = try await makeRepository(in: base)
            let idle = try await VMR.vmr(["hooks", "pre-commit"], in: repository)
            #expect(idle.status == 0, "nothing staged: \(idle.combined)")

            try write(["Sources/Bad.swift": Self.badlyFormatted], to: repository)
            _ = try await git(["add", "Sources/Bad.swift"], in: repository)
            let blocked = try await VMR.vmr(["hooks", "pre-commit"], in: repository)
            #expect(blocked.status == 1, "\(blocked.combined)")

            let bypass = try await git(["commit", "-q", "--no-verify", "-m", "bypass"], in: repository)
            #expect(bypass.status == 0, "\(bypass.combined)")
        }
    }

    @Test
    func installRefusesToOverwriteAForeignHookButReplacesAStaleLink() async throws {
        try await withTemporaryDirectory { base in
            let repository = try await makeRepository(in: base, install: false)
            let hook = repository.appending(path: ".git/hooks/pre-commit")
            try write([".git/hooks/pre-commit": "#!/bin/sh\nexit 0\n"], to: repository)
            let refused = try await VMR.vmr(["hooks", "install"], in: repository)
            #expect(refused.status == 1)
            #expect(refused.error.contains("was not installed by vmr"), "\(refused.error)")
            #expect(try String(contentsOf: hook, encoding: .utf8).contains("exit 0"), "the foreign hook is untouched")

            try FileManager.default.removeItem(at: hook)
            try FileManager.default.createSymbolicLink(
                atPath: hook.path, withDestinationPath: base.appending(path: "gone/.build/debug/vmr").path)
            let replaced = try await VMR.vmr(["hooks", "install"], in: repository)
            #expect(replaced.status == 0, "a dangling link to an old vmr build is replaced: \(replaced.combined)")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: hook.path) == (try VMR.binary(named: "vmr")).path)
        }
    }

    @Test
    func installDropsTheLegacyHooksPathAndOutsideARepositoryItFails() async throws {
        try await withTemporaryDirectory { base in
            let repository = try await makeRepository(in: base, install: false)
            _ = try await git(["config", "core.hooksPath", ".githooks"], in: repository)
            let run = try await VMR.vmr(["hooks", "install"], in: repository)
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output.contains("removed core.hooksPath=.githooks"))
            let configured = try await git(["config", "--get", "core.hooksPath"], in: repository)
            #expect(configured.status != 0, "core.hooksPath is unset")

            let elsewhere = base.appending(path: "plain", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let outside = try await VMR.vmr(["hooks", "install"], in: elsewhere)
            #expect(outside.status == 1)
            #expect(outside.error.contains("is not a git repository"), "\(outside.error)")
        }
    }
}
