import CryptoKit
import Foundation

/// Installs the pinned analyzer releases into a tools directory (git-ignored `.tools/` by default).
///
/// The archive's SHA-256 is checked against the value pinned in the lock file, not against a checksum shipped with
/// the release, and nothing from the archive is listed, unpacked or executed before that check passes.
struct AnalyzerInstaller: Sendable {
    let toolsDirectory: URL
    let location: ReleaseLocation
    let downloader: any ArchiveDownloader

    /// The directory a pinned release is installed in.
    func installDirectory(for pin: AnalyzerPin) -> URL {
        toolsDirectory.appending(path: "\(pin.tool.rawValue)-\(pin.version)", directoryHint: .isDirectory)
    }

    func binary(for pin: AnalyzerPin) -> URL {
        installDirectory(for: pin).appending(path: pin.tool.rawValue)
    }

    /// Returns the installed binary, downloading and verifying the release first when it is missing.
    func install(_ pin: AnalyzerPin) async throws -> URL {
        let destination = binary(for: pin)
        if FileManager.default.isExecutableFile(atPath: destination.path) { return destination }
        guard Platform.isMacOSArm64 else {
            throw ToolError(
                "the pinned \(pin.tool.rawValue) release is macOS arm64 only; set \(pin.tool.binaryOverrideVariable) to a binary you trust"
            )
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        let scratch = toolsDirectory.appending(path: ".download.\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: scratch) }

        let source = try location.archiveURL(for: pin)
        Output.out("installing \(pin.tool.rawValue) \(pin.version) from \(source.absoluteString)")
        let archive = scratch.appending(path: "\(pin.tool.rawValue).tar.gz")
        try await downloader.download(from: source, to: archive)

        let actual = try Self.sha256(ofFileAt: archive)
        guard actual == pin.sha256 else {
            throw ToolError(
                "\(pin.tool.rawValue) \(pin.version): SHA-256 mismatch (expected \(pin.sha256), got \(actual)); refusing to run it")
        }
        try await Self.checkArchiveLayout(archive, pin: pin)

        let extracted = scratch.appending(path: "extract", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false)
        try await Self.tar(["-xzf", archive.path, "-C", extracted.path])
        let release = extracted.appending(path: pin.directoryInArchive, directoryHint: .isDirectory)
        let unpacked = release.appending(path: pin.tool.rawValue)
        guard fileManager.isExecutableFile(atPath: unpacked.path) else {
            throw ToolError("\(pin.tool.rawValue) \(pin.version): archive layout changed")
        }
        let reported = try await Self.reportedVersion(of: unpacked)
        guard reported == pin.version else {
            throw ToolError("\(pin.tool.rawValue) binary reports '\(reported)', expected '\(pin.version)'")
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
        let listing = try await tar(["-tzf", archive.path])
        let escapes = listing.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }
        if escapes {
            throw ToolError("\(pin.tool.rawValue) \(pin.version): archive contains absolute or parent-relative paths")
        }
    }

    @discardableResult
    private static func tar(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(CommandSpec(executable: "/usr/bin/tar", arguments: arguments))
        guard result.succeeded else { throw ToolError("tar \(arguments[0]) failed: \(result.standardError)") }
        return result.standardOutput
    }
}

enum Platform {
    #if arch(arm64)
        static let isMacOSArm64 = true
    #else
        static let isMacOSArm64 = false
    #endif
}
