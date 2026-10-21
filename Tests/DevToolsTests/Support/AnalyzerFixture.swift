import Foundation

@testable import DevTools

/// A package root with a pins file, matching workflows and a LOCAL release: the arcleak, dolly and deadwood archives
/// are tarballs of the `FakeAnalyzer` binary, served from a directory through `VMR_ANALYZERS_BASE_URL=file://...`.
struct AnalyzerFixture {
    static let version = "1.2.3"

    let root: URL
    let release: URL
    let logFile: URL

    static func commit(of tool: AnalyzerTool) -> String {
        let digit =
            switch tool {
            case .arcleak: "a"
            case .dolly: "b"
            case .deadwood: "c"
            }
        return String(repeating: digit, count: 40)
    }

    static func lockText(sha: (AnalyzerTool) -> String) -> String {
        AnalyzerTool.allCases.map { tool in
            let prefix = tool.rawValue.uppercased()
            return "\(prefix)_VERSION=\(version)\n\(prefix)_COMMIT=\(commit(of: tool))\n\(prefix)_SHA256_MACOS_ARM64=\(sha(tool))\n"
        }.joined(separator: "\n")
    }

    static func workflowText(commit: (AnalyzerTool) -> String = commit(of:), version: (AnalyzerTool) -> String = { _ in version }) -> String
    {
        let steps = AnalyzerTool.allCases.map { tool in
            """
                  - uses: g-cqd/\(tool.rawValue)@\(commit(tool)) # v\(version(tool))
                    with:
                      version: '\(version(tool))' # \(tool.rawValue)
            """
        }.joined(separator: "\n")
        return "name: CI\njobs:\n  analyzers:\n    steps:\n\(steps)\n"
    }

    /// Builds the fixture below `base`. Archives named in `tampered` get an extra file after their digest was pinned.
    static func make(in base: URL, tampered: Set<AnalyzerTool> = []) async throws -> Self {
        let root = base.appending(path: "package", directoryHint: .isDirectory)
        let release = base.appending(path: "release", directoryHint: .isDirectory)
        let stage = base.appending(path: "stage", directoryHint: .isDirectory)
        for directory in [root.appending(path: "Sources"), root.appending(path: "Tests"), release, stage] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fake = try VMR.binary(named: "FakeAnalyzer")

        var digests: [AnalyzerTool: String] = [:]
        for tool in AnalyzerTool.allCases {
            let pin = AnalyzerPin(tool: tool, version: version, commit: commit(of: tool), sha256: "")
            let directory = stage.appending(path: "\(tool.rawValue)/\(pin.directoryInArchive)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fake, to: directory.appending(path: tool.rawValue))
            let archive = release.appending(path: pin.archiveName)
            try await pack(directory: pin.directoryInArchive, in: stage.appending(path: tool.rawValue), to: archive)
            digests[tool] = try AnalyzerInstaller.sha256(ofFileAt: archive)
            if tampered.contains(tool) {
                try Data("not what was pinned".utf8).write(to: directory.appending(path: "extra"))
                try FileManager.default.removeItem(at: archive)
                try await pack(directory: pin.directoryInArchive, in: stage.appending(path: tool.rawValue), to: archive)
            }
        }

        try write(
            [
                "Scripts/analyzers.lock": lockText { digests[$0] ?? "" },
                ".github/workflows/ci.yml": workflowText(),
            ],
            to: root
        )
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
        let log = URL(fileURLWithPath: "\(logFile.path).\(tool.rawValue)")
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private static func pack(directory: String, in parent: URL, to archive: URL) async throws {
        let run = try await VMR.run("/usr/bin/tar", ["-czf", archive.path, "-C", parent.path, directory], in: parent)
        guard run.status == 0 else { throw TestSetupError("tar failed: \(run.error)") }
    }
}
