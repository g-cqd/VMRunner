import CryptoKit
import Foundation

/// Installs the pinned releases (the analyzers and SwiftLint) into a tools directory (git-ignored `.tools/` by default).
///
/// The archive's SHA-256 is checked against the value pinned in the lock file, not against a checksum shipped with
/// the release, and nothing from the archive is listed, unpacked or executed before that check passes.
///
/// Nothing in the checkout is trusted on its own: a pull request can commit a file under `.tools/` with `git add -f`.
/// An installed release is reused only when git tracks nothing under the tools directory and the stamp written after
/// the verified install still names the lock's archive digest and the binary's own digest. Anything else is
/// reinstalled from the verified archive.
struct AnalyzerInstaller: Sendable {
    let toolsDirectory: URL
    let location: ReleaseLocation
    let downloader: any ArchiveDownloader

    /// The directory a pinned release is installed in.
    func installDirectory(for pin: AnalyzerPin) -> URL {
        toolsDirectory.appending(path: "\(pin.release.name)-\(pin.version)", directoryHint: .isDirectory)
    }

    func binary(for pin: AnalyzerPin) -> URL {
        installDirectory(for: pin).appending(path: pin.release.name)
    }

    /// Returns the installed binary, downloading and verifying the release first when it is missing, unstamped or changed.
    func install(_ pin: AnalyzerPin) async throws -> URL {
        let name = pin.release.name
        let destination = binary(for: pin)
        try await refuseTrackedTools()
        if try Self.isVerified(pin, binary: destination, in: installDirectory(for: pin)) { return destination }
        guard Platform.isMacOSArm64 else {
            throw ToolError(
                "the pinned \(name) release is macOS arm64 only; set \(pin.release.binaryOverrideVariable) to a binary you trust")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        let scratch = toolsDirectory.appending(path: ".download.\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: scratch) }

        let source = try location.archiveURL(for: pin)
        Output.out("installing \(name) \(pin.version) from \(source.absoluteString)")
        let archive = scratch.appending(path: pin.archiveName)
        try await downloader.download(from: source, to: archive)

        let actual = try Self.sha256(ofFileAt: archive)
        guard actual == pin.sha256 else {
            throw ToolError("\(name) \(pin.version): SHA-256 mismatch (expected \(pin.sha256), got \(actual)); refusing to run it")
        }
        try await Self.checkArchiveLayout(archive, pin: pin)

        let extracted = scratch.appending(path: "extract", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false)
        let compression = pin.release.archive.tarCompression
        try await Self.tar(["-x\(compression)f", archive.path, "-C", extracted.path])
        let release = pin.directoryInArchive.map { extracted.appending(path: $0, directoryHint: .isDirectory) } ?? extracted
        let unpacked = release.appending(path: name)
        guard fileManager.isExecutableFile(atPath: unpacked.path) else {
            throw ToolError("\(name) \(pin.version): archive layout changed")
        }
        let reported = try await Self.reportedVersion(of: unpacked)
        guard reported == pin.version else {
            throw ToolError("\(name) binary reports '\(reported)', expected '\(pin.version)'")
        }
        let stamp = Self.stamp(for: pin, binarySHA256: try Self.sha256(ofFileAt: unpacked))
        try stamp.write(to: release.appending(path: Self.stampName), atomically: true, encoding: .utf8)

        try? fileManager.removeItem(at: installDirectory(for: pin))
        try fileManager.moveItem(at: release, to: installDirectory(for: pin))
        return destination
    }

    // MARK: Trust in what is already on disk

    static let stampName = ".vmr-verified"

    /// What a verified install records: the lock's archive digest and the digest of the binary taken out of it.
    static func stamp(for pin: AnalyzerPin, binarySHA256: String) -> String {
        "archive-sha256=\(pin.sha256)\nbinary-sha256=\(binarySHA256)\n"
    }

    /// Whether the binary on disk is the one a verified install of this pin produced: it is executable, the stamp
    /// names the lock's current archive digest, and the binary hashes to the digest the stamp recorded.
    static func isVerified(_ pin: AnalyzerPin, binary: URL, in directory: URL) throws -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary.path),
            let recorded = try? String(contentsOf: directory.appending(path: stampName), encoding: .utf8)
        else { return false }
        return recorded == stamp(for: pin, binarySHA256: try sha256(ofFileAt: binary))
    }

    /// Refuses a tools directory that git tracks anything in: a committed file is a pull request's, not a download this
    /// tool verified. Skipped when git is missing or the directory is in no repository (`--error-unmatch` exits 0 for a
    /// tracked path and 1 for an untracked one; any other outcome is "git cannot tell").
    func refuseTrackedTools() async throws {
        guard (try? FileManager.default.attributesOfItem(atPath: toolsDirectory.path)) != nil else { return }
        // A relative pathspec from the parent: it holds when a temporary directory is reached through a symlink.
        let spec = CommandSpec(
            executable: "/usr/bin/git",  // absolute, like tar: PATH decides nothing here
            arguments: ["ls-files", "--error-unmatch", "--", toolsDirectory.lastPathComponent],
            workingDirectory: toolsDirectory.deletingLastPathComponent()
        )
        guard let result = try? await ProcessRunner.run(spec), result.status == 0 else { return }
        throw ToolError(
            "git tracks files under \(toolsDirectory.path): a tool a commit carries is not one this tool verified. "
                + "Remove them from the index (git rm -r --cached) and from the tree; vmr downloads the pinned release itself")
    }

    /// The hex SHA-256 of a file, hashed in chunks so a large archive is never held in memory.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    /// What `<binary> --version` prints, without its trailing newline.
    static func reportedVersion(of binary: URL) async throws -> String {
        let result = try await ProcessRunner.run(CommandSpec(executable: binary.path, arguments: ["--version"]))
        guard result.succeeded else { throw ToolError("\(binary.lastPathComponent) --version exited with status \(result.status)") }
        return Self.version(fromReport: result.standardOutput, name: binary.lastPathComponent)
    }

    /// The version in a `--version` report: its first line without surrounding blanks or a leading `<name> `. zizmor prints
    /// `zizmor 1.31.1`; actionlint prints the version alone on its first line, then how it was built.
    static func version(fromReport report: String, name: String) -> String {
        let firstLine = report.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let prefix = "\(name) "
        return firstLine.hasPrefix(prefix) ? String(firstLine.dropFirst(prefix.count)) : firstLine
    }

    private static func checkArchiveLayout(_ archive: URL, pin: AnalyzerPin) async throws {
        let listing = try await tar(["-t\(pin.release.archive.tarCompression)f", archive.path])
        let escapes = listing.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }
        if escapes {
            throw ToolError("\(pin.release.name) \(pin.version): archive contains absolute or parent-relative paths")
        }
    }

    @discardableResult
    private static func tar(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(CommandSpec(executable: "/usr/bin/tar", arguments: arguments))
        guard result.succeeded else { throw ToolError("tar \(arguments[0]) failed: \(result.standardError)") }
        return result.standardOutput
    }
}

extension AnalyzerInstaller {
    /// The installer for a checkout: `ANALYZERS_DIR` or `<root>/.tools`, and the release location `VMR_ANALYZERS_BASE_URL` selects.
    init(root: URL, environment: [String: String], downloader: any ArchiveDownloader = URLArchiveDownloader()) throws {
        self.init(
            toolsDirectory: environment["ANALYZERS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? root.appending(path: ".tools", directoryHint: .isDirectory),
            location: try ReleaseLocation(environment: environment),
            downloader: downloader
        )
    }
}

enum Platform {
    #if arch(arm64)
        static let isMacOSArm64 = true
    #else
        static let isMacOSArm64 = false
    #endif
}
