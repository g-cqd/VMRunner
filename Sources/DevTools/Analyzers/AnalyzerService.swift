import Foundation

/// Installs and runs the pinned analyzers over `Sources` and `Tests`.
///
/// The analyzers' own exit codes: 1 means findings, 64 usage, 70 nothing analyzed, 74 write error, 78 bad
/// configuration or baseline. Only 1 means "the code has findings"; the others mean the gate itself is broken.
struct AnalyzerService: Sendable {
    /// An analyzer ready to run. `version` is known (and verified) for a pinned release, not for a `<TOOL>_BIN` override.
    struct Resolved: Sendable {
        let binary: URL
        let version: String?
    }

    typealias Resolution = Result<Resolved, any Error>

    let root: URL
    let environment: [String: String]
    var downloader: any ArchiveDownloader = URLArchiveDownloader()
    /// When set, each analyzer's output is streamed through it to count findings for the job summary.
    var facts: GateFacts?

    private static let cachePath = ".build-analyzers"

    // MARK: Commands

    /// Analyzes with each tool. Returns whether everything passed.
    func run(tools: [AnalyzerTool]) async throws -> Bool {
        let lock = try AnalyzerLock.load(root: root)
        var passed = true
        let resolutions = await resolve(tools, lock: lock)
        for tool in tools {
            switch resolutions[tool] {
            case .success(let resolved):
                passed = await analyze(tool, with: resolved) && passed
            case .failure(let error):
                Output.err("error: \(error)")
                Output.out("FAIL  \(tool.rawValue): not installed")
                passed = false
            case nil:
                passed = false
            }
        }
        return passed
    }

    /// Downloads and verifies the pinned releases without running them.
    func install(tools: [AnalyzerTool]) async throws {
        let resolutions = await resolve(tools, lock: try AnalyzerLock.load(root: root))
        for tool in tools {
            _ = try resolutions[tool]?.get()
        }
    }

    /// Accepts the current findings into `.<tool>-baseline.json`, so only new findings fail the gate.
    func writeBaselines(tools: [AnalyzerTool]) async throws {
        let resolutions = await resolve(tools, lock: try AnalyzerLock.load(root: root))
        for tool in tools {
            guard let resolved = try resolutions[tool]?.get() else { continue }
            let arguments = analysisArguments(for: tool) + ["--write-baseline", Self.baselineName(for: tool)]
            let result = try await ProcessRunner.run(
                CommandSpec(executable: resolved.binary.path, arguments: arguments, workingDirectory: root),
                output: .inherit
            )
            guard result.succeeded else {
                throw ToolError("\(tool.rawValue) could not write its baseline (exit \(result.status))", status: result.status)
            }
        }
    }

    func versions() throws {
        let lock = try AnalyzerLock.load(root: root)
        for release in ReleaseSpec.pinnedReleases {
            let pin = try lock.pin(for: release)
            Output.out("\(release.name) \(pin.version) (commit \(pin.commit))")
        }
    }

    // MARK: Pieces

    private static func baselineName(for tool: AnalyzerTool) -> String { ".\(tool.rawValue)-baseline.json" }

    /// Resolves every tool concurrently, so the first run downloads the releases in parallel.
    private func resolve(_ tools: [AnalyzerTool], lock: AnalyzerLock) async -> [AnalyzerTool: Resolution] {
        await withTaskGroup(of: (AnalyzerTool, Resolution).self) { group in
            for tool in tools {
                group.addTask {
                    do {
                        return (tool, .success(try await resolve(tool, lock: lock)))
                    } catch {
                        return (tool, .failure(error))
                    }
                }
            }
            var resolutions: [AnalyzerTool: Resolution] = [:]
            for await (tool, resolution) in group {
                resolutions[tool] = resolution
            }
            return resolutions
        }
    }

    /// The `<TOOL>_BIN` override when set, otherwise the pinned release (downloaded and verified on first use).
    private func resolve(_ tool: AnalyzerTool, lock: AnalyzerLock) async throws -> Resolved {
        if let override = environment[tool.release.binaryOverrideVariable], !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else { throw ToolError("\(override) is not an executable") }
            ToolLocator.noteOverride(variable: tool.release.binaryOverrideVariable, path: override, environment: environment)
            return Resolved(binary: URL(fileURLWithPath: override), version: nil)
        }
        let pin = try lock.pin(for: tool)
        let installer = try AnalyzerInstaller(root: root, environment: environment, downloader: downloader)
        return Resolved(binary: try await installer.install(pin), version: pin.version)
    }

    /// `analyze Sources Tests ...`, the part shared by a normal run and by writing a baseline.
    private func analysisArguments(for tool: AnalyzerTool) -> [String] {
        let name = tool.rawValue
        return [
            "analyze", "Sources", "Tests", "--relative-to", ".", "--config", ".\(name).json",
            "--cache-path", "\(Self.cachePath)/\(name)-facts.json",
        ]
    }

    private func analyze(_ tool: AnalyzerTool, with resolved: Resolved) async -> Bool {
        var arguments = analysisArguments(for: tool)
        if tool.isStrict { arguments.append("--strict") }
        let baseline = Self.baselineName(for: tool)
        if FileManager.default.fileExists(atPath: root.appending(path: baseline).path) {
            arguments += ["--baseline", baseline]
        }
        do {
            try FileManager.default.createDirectory(at: root.appending(path: Self.cachePath), withIntermediateDirectories: true)
            let version: String
            if let known = resolved.version {
                version = known
            } else {
                version = try await AnalyzerInstaller.reportedVersion(of: resolved.binary)
            }
            Output.out("--- \(tool.rawValue) \(version): \(arguments.joined(separator: " "))")
            let result = try await ProcessRunner.run(
                CommandSpec(executable: resolved.binary.path, arguments: arguments, workingDirectory: root),
                output: outputMode(for: tool)
            )
            return report(tool, status: result.status)
        } catch {
            Output.err("error: \(error)")
            Output.out("FAIL  \(tool.rawValue): \(error)")
            return false
        }
    }

    private func outputMode(for tool: AnalyzerTool) -> OutputMode {
        guard let facts else { return .inherit }
        facts.analyzerStarted(tool)
        return .stream { facts.observeAnalyzer(tool, line: $0) }
    }

    private func report(_ tool: AnalyzerTool, status: Int32) -> Bool {
        switch status {
        case 0:
            Output.out("PASS  \(tool.rawValue)")
            return true
        case 1:
            Output.out("FAIL  \(tool.rawValue): findings (exit 1)")
        default:
            let codes = "64 usage, 70 nothing analyzed, 78 bad config or baseline"
            Output.out("FAIL  \(tool.rawValue): the analyzer itself failed (exit \(status): \(codes))")
        }
        return false
    }
}
