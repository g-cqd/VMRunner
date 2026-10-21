import Foundation

/// Installs `vmr` itself as the repository's `pre-commit` hook.
///
/// A git hook is any executable, so the hook is a symbolic link named `pre-commit` that points at the built `vmr`
/// binary. When git runs it, `vmr` sees it was invoked as `pre-commit` and runs the fast checks on the staged files
/// (see `PreCommit`).
///
/// Trade-offs:
///  * The link points at the binary where it was built (for example `.build/arm64-apple-macosx/debug/vmr`), not at
///    a copy, so every `swift build` or `swift run vmr` updates the hook with no reinstall.
///  * After `swift package clean` or `rm -rf .build` the link dangles, and git then skips the hook with a hint
///    instead of failing the commit. Build again (`swift build --product vmr`) or re-run `swift run vmr hooks install`.
///  * A fresh clone has no binary yet: `swift run vmr hooks install` builds `vmr` and installs it in one step.
struct HookInstaller {
    static let hookName = "pre-commit"

    let git: Git
    /// The `vmr` binary the hook links to.
    let executable: URL

    func install() async throws {
        let top = try await git.topLevel()
        let topGit = Git(directory: top)
        try await dropLegacyHooksPath(topGit)

        let hooksDirectory = try await hooksDirectory(topGit, top: top)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        let link = hooksDirectory.appending(path: Self.hookName)
        try removeOwnLink(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        Output.out("git hook installed: \(link.path) -> \(executable.path)")
    }

    /// The previous shell hook lived in `.githooks` and was enabled with `core.hooksPath`; that directory is gone.
    private func dropLegacyHooksPath(_ git: Git) async throws {
        guard let configured = try? await git.output(["config", "--local", "--get", "core.hooksPath"]), configured == ".githooks" else {
            return
        }
        _ = try await git.output(["config", "--local", "--unset", "core.hooksPath"])
        Output.out("removed core.hooksPath=.githooks (the shell hook it pointed at no longer exists)")
    }

    /// Where git looks for hooks: `.git/hooks`, the shared one of a linked worktree, or `core.hooksPath`.
    private func hooksDirectory(_ git: Git, top: URL) async throws -> URL {
        let path = try await git.output(["rev-parse", "--git-path", "hooks"])
        return URL(fileURLWithPath: path, relativeTo: top).standardizedFileURL
    }

    /// Replaces an earlier link to a `vmr` binary (possibly dangling); refuses to overwrite any other hook.
    private func removeOwnLink(at link: URL) throws {
        let fileManager = FileManager.default
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
            guard URL(fileURLWithPath: target).lastPathComponent == executable.lastPathComponent else {
                throw ToolError("\(link.path) is a link to \(target), not to vmr; move it aside and run `vmr hooks install` again")
            }
            try fileManager.removeItem(at: link)
        } else if fileManager.fileExists(atPath: link.path) {
            throw ToolError("\(link.path) already exists and was not installed by vmr; move it aside and run `vmr hooks install` again")
        }
    }
}
