import Foundation

@testable import DevTools

/// A package root with a lock file and a LOCAL release: the arcleak, dolly and deadwood archives are tarballs of the
/// `FakeAnalyzer` binary and the SwiftLint archive is a flat zip of it, all served from a directory through
/// `VMR_ANALYZERS_BASE_URL=file://...`.
struct AnalyzerFixture {
    static let version = "1.2.3"
    /// The analyzers and SwiftLint: every release the lock pins.
    static let releases = ReleaseSpec.pinnedReleases

    let root: URL
    let release: URL
    let logFile: URL

    static func commit(of tool: AnalyzerTool) -> String {
        commit(of: tool.release)
    }

    static func commit(of release: ReleaseSpec) -> String {
        let digit =
            switch release.name {
            case "arcleak": "a"
            case "dolly": "b"
            case "deadwood": "c"
            default: "d"
            }
        return String(repeating: digit, count: 40)
    }

    static func lockText(sha: (ReleaseSpec) -> String) -> String {
        releases.map { release in
            let prefix = release.name.uppercased()
            return "\(prefix)_VERSION=\(version)\n\(prefix)_COMMIT=\(commit(of: release))\n\(prefix)_SHA256_MACOS_ARM64=\(sha(release))\n"
        }.joined(separator: "\n")
    }

    /// Builds the fixture below `base`. Releases named in `tampered` get an extra file after their digest was pinned.
    /// `lockText` replaces the lock the fixture would pin for its own releases.
    static func make(in base: URL, tampered: Set<String> = [], lockText: String? = nil) async throws -> Self {
        let root = base.appending(path: "package", directoryHint: .isDirectory)
        let release = base.appending(path: "release", directoryHint: .isDirectory)
        let stage = base.appending(path: "stage", directoryHint: .isDirectory)
        for directory in [root.appending(path: "Sources"), root.appending(path: "Tests"), release, stage] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fake = try VMR.binary(named: "FakeAnalyzer")

        var digests: [String: String] = [:]
        for spec in releases {
            let name = spec.name
            let pin = AnalyzerPin(release: spec, version: version, commit: commit(of: spec), sha256: "")
            let parent = stage.appending(path: name, directoryHint: .isDirectory)
            let content = pin.directoryInArchive.map { parent.appending(path: $0, directoryHint: .isDirectory) } ?? parent
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fake, to: content.appending(path: name))
            let archive = release.appending(path: pin.archiveName)
            try await pack(pin, content: content, parent: parent, to: archive)
            digests[name] = try AnalyzerInstaller.sha256(ofFileAt: archive)
            if tampered.contains(name) {
                try Data("not what was pinned".utf8).write(to: content.appending(path: "extra"))
                try FileManager.default.removeItem(at: archive)
                try await pack(pin, content: content, parent: parent, to: archive)
            }
        }

        try write(["Scripts/analyzers.lock": lockText ?? Self.lockText { digests[$0.name] ?? "" }], to: root)
        return Self(root: root, release: release, logFile: base.appending(path: "analyzer.log"))
    }

    /// The environment that points vmr at the local release and makes the fake report the pinned version.
    func environment(adding extra: [String: String] = [:]) -> [String: String] {
        [
            "VMR_ANALYZERS_BASE_URL": release.absoluteString,
            "FAKE_ANALYZER_VERSION": Self.version,
            "FAKE_ANALYZER_LOG": logFile.path,
        ].merging(extra) { _, new in new }
    }

    /// Runs `vmr <arguments> --root <fixture root>` against this fixture.
    @discardableResult
    func vmr(_ arguments: [String], environment extra: [String: String] = [:]) async throws -> Invocation {
        try await VMR.vmr(arguments + ["--root", root.path], in: root, environment: environment(adding: extra))
    }

    /// What the fake recorded for `tool`, one `<tool> <arguments>` line per call, `--version` probes included.
    func loggedCalls(of tool: AnalyzerTool) -> [String] {
        loggedCalls(of: tool.rawValue)
    }

    func loggedCalls(of name: String) -> [String] {
        let log = URL(fileURLWithPath: "\(logFile.path).\(name)")
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: A release a commit carries

    /// Where the planted scripts record that they ran.
    var plantedLog: URL { logFile.deletingLastPathComponent().appending(path: "planted.log") }

    /// How many times a planted script ran.
    var plantedRuns: Int {
        ((try? String(contentsOf: plantedLog, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func toolDirectory(_ name: String) -> URL {
        root.appending(path: ".tools/\(name)-\(Self.version)", directoryHint: .isDirectory)
    }

    /// Writes `.tools/<name>-<version>/<name>`: an executable script that logs and exits 0, as a pull request could commit.
    @discardableResult
    func plantScript(named name: String) throws -> URL {
        let binary = toolDirectory(name).appending(path: name)
        try write([".tools/\(name)-\(Self.version)/\(name)": "#!/bin/sh\necho ran >> '\(plantedLog.path)'\nexit 0\n"], to: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    /// Rewrites the install stamp so it vouches for whatever binary is there now: what a commit that carries both can do.
    func forgeStamp(for release: ReleaseSpec) throws {
        let pin = try AnalyzerLock.load(root: root).pin(for: release)
        let binary = toolDirectory(release.name).appending(path: release.name)
        let stamp = AnalyzerInstaller.stamp(for: pin, binarySHA256: try AnalyzerInstaller.sha256(ofFileAt: binary))
        try write([".tools/\(release.name)-\(Self.version)/\(AnalyzerInstaller.stampName)": stamp], to: root)
    }

    /// Makes git track everything under `.tools/` the way `git add -f` does.
    func trackTools() async throws {
        for command in [["init", "-q", "-b", "main"], ["add", "-f", ".tools"]] {
            let run = try await VMR.run("git", command, in: root)
            guard run.status == 0 else { throw TestSetupError("git \(command.joined(separator: " ")) failed: \(run.combined)") }
        }
    }

    /// A tarball of the release's directory, or a zip of the files at its root.
    private static func pack(_ pin: AnalyzerPin, content: URL, parent: URL, to archive: URL) async throws {
        let run: Invocation
        switch pin.release.archive {
        case .versionedTarball:
            run = try await VMR.run("/usr/bin/tar", ["-czf", archive.path, "-C", parent.path, content.lastPathComponent], in: parent)
        case .flatZip:
            run = try await VMR.run("/usr/bin/zip", ["-q", "-r", archive.path, "."], in: content)
        }
        guard run.status == 0 else { throw TestSetupError("packing \(archive.lastPathComponent) failed: \(run.error)") }
    }
}
