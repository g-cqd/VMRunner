import CryptoKit
import Foundation

/// Installs the pinned releases (the analyzers and SwiftLint) into a tools directory (git-ignored `.tools/` by default).
///
/// The archive's SHA-256 is checked against the value pinned in the lock file, not against a checksum shipped with
/// the release, and nothing from the archive is listed, unpacked or executed before that check passes.
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

    /// Returns the installed binary, downloading and verifying the release first when it is missing.
    func install(_ pin: AnalyzerPin) async throws -> URL {
        let name = pin.release.name
        let destination = binary(for: pin)
        if FileManager.default.isExecutableFile(atPath: destination.path) { return destination }
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

        try? fileManager.removeItem(at: installDirectory(for: pin))
        try fileManager.moveItem(at: release, to: installDirectory(for: pin))
        return destination
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
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
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
