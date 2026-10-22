import Foundation

/// The programs and transfers `vmr guest fetch` depends on, replaceable by a test.
struct NetbootDependencies {
    /// Runs a program and returns what it printed.
    var run: @Sendable (CommandSpec) async throws -> CommandResult
    /// A downloader that refuses a transfer larger than the given number of bytes.
    var downloader: @Sendable (_ maximumBytes: Int) -> any ArchiveDownloader
    /// The `gpg` to verify the signature with, or `nil` when none is installed.
    var gpg: String?

    static func system(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        Self(
            run: { try await ProcessRunner.run($0) },
            downloader: { URLArchiveDownloader(maximumBytes: $0) },
            gpg: try? ToolLocator.resolve("gpg", searchPath: environment["PATH"]).path)
    }
}

/// The files of a fetched netboot image, ready to boot from.
struct NetbootFiles: Equatable {
    let directory: URL
    let version: String

    var kernel: URL { directory.appending(path: "Image-virt") }
    var initramfs: URL { directory.appending(path: "initramfs-virt") }
    /// The kernel as shipped, an EFI application that holds the compressed kernel.
    var packagedKernel: URL { directory.appending(path: "vmlinuz-virt") }
    var releaseFile: URL { directory.appending(path: "release") }

    /// The files of an earlier fetch into `scratch`, or an error saying what is missing.
    static func existing(in scratch: GuestScratch) throws -> Self {
        let directory = scratch.netbootDirectory
        let version = (try? String(contentsOf: directory.appending(path: "release"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let files = Self(directory: directory, version: version ?? "")
        for file in [files.kernel, files.initramfs] where !FileManager.default.fileExists(atPath: file.path) {
            throw ToolError("\(file.path) does not exist; run `vmr guest fetch alpine-netboot --directory \(scratch.root.path)` first")
        }
        return files
    }
}

/// `vmr guest fetch alpine-netboot`: downloads the newest signed aarch64 netboot release into an empty scratch directory,
/// checks it, and unpacks the three files a guest boots from.
///
/// Nothing is trusted until it was checked: the archive against the vendor's `.sha256`, its `.asc` against the release
/// signer's key (when `gpg` is installed; the key file itself is accepted only with the pinned fingerprint), and its
/// listing for anything but plain files and directories inside the target directory.
struct NetbootFetch {
    static let archiveLimit = 768 << 20
    static let smallFileLimit = 1 << 20
    /// The members unpacked from the archive; the rest (the Raspberry Pi files, the device trees) is never written.
    static let members = ["boot/vmlinuz-virt", "boot/initramfs-virt", "boot/modloop-virt"]

    let scratch: GuestScratch
    var dependencies = NetbootDependencies.system()
    var say: @Sendable (String) -> Void = { Output.out($0) }

    func run() async throws -> NetbootFiles {
        try prepare()
        let listing = scratch.downloadDirectory.appending(path: "listing.html")
        guard let directoryURL = AlpineNetboot.url(of: "") else { throw ToolError("cannot form the release directory URL") }
        try await dependencies.downloader(Self.smallFileLimit).download(from: directoryURL, to: listing)
        let html = String(bytes: try Data(contentsOf: listing), encoding: .utf8) ?? ""
        let choice = try AlpineNetboot.choose(from: AlpineNetboot.releases(inListing: html))
        let release = choice.release
        if !choice.passedOver.isEmpty {
            say("passed over \(choice.passedOver.joined(separator: ", ")): published without a .asc signature yet")
        }
        say("release: Alpine netboot \(release.version) (aarch64)")

        let archive = scratch.downloadDirectory.appending(path: release.archive)
        let checksumFile = scratch.downloadDirectory.appending(path: release.checksumFile)
        let signatureFile = scratch.downloadDirectory.appending(path: release.signatureFile)
        try await download(release.checksumFile, to: checksumFile, limit: Self.smallFileLimit)
        try await download(release.signatureFile, to: signatureFile, limit: Self.smallFileLimit)
        try await download(release.archive, to: archive, limit: Self.archiveLimit)

        try verifyChecksum(of: archive, against: checksumFile, named: release.archive)
        try await verifySignature(of: archive, signature: signatureFile)

        let files = NetbootFiles(directory: scratch.netbootDirectory, version: release.version)
        try await unpack(archive, into: files)
        try? FileManager.default.removeItem(at: archive)
        say("files in \(files.directory.path): vmlinuz-virt, Image-virt, initramfs-virt, modloop-virt")
        return files
    }

    // MARK: Steps

    /// The scratch directory must be new or empty: a fetch never mixes its files with others.
    private func prepare() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: scratch.root.path) {
            let entries = try fileManager.contentsOfDirectory(atPath: scratch.root.path).filter { $0 != ".DS_Store" }
            guard entries.isEmpty else {
                throw ToolError(
                    "\(scratch.root.path) is not empty (\(entries.sorted().joined(separator: ", "))); fetch into an empty directory")
            }
        }
        try GuestScratch.ensurePrivate(scratch.root)
        try GuestScratch.ensurePrivate(scratch.downloadDirectory)
        try GuestScratch.ensurePrivate(scratch.netbootDirectory)
    }

    private func download(_ file: String, to destination: URL, limit: Int) async throws {
        guard let url = AlpineNetboot.url(of: file) else { throw ToolError("cannot form the URL of \(file)") }
        say("downloading \(file)")
        try await dependencies.downloader(limit).download(from: url, to: destination)
    }

    private func verifyChecksum(of archive: URL, against checksumFile: URL, named name: String) throws {
        let text = String(bytes: try Data(contentsOf: checksumFile), encoding: .utf8) ?? ""
        let expected = try NetbootChecks.digest(inChecksumFile: text, for: name)
        let actual = try AnalyzerInstaller.sha256(ofFileAt: archive)
        guard actual == expected else {
            throw ToolError("the SHA-256 of \(name) is \(actual), but the vendor's .sha256 says \(expected); refusing it")
        }
        say("sha256 OK: \(actual)")
    }

    private func verifySignature(of archive: URL, signature: URL) async throws {
        guard let gpg = dependencies.gpg else {
            say(
                "NOT VERIFIED: gpg is not installed, so the .asc signature was not checked (only the .sha256, which the same server serves)"
            )
            return
        }
        let keyFile = scratch.downloadDirectory.appending(path: "alpine-release-key.asc")
        guard let keyURL = URL(string: AlpineNetboot.keyURL) else { throw ToolError("cannot form the key URL") }
        say("downloading the release signer's key")
        try await dependencies.downloader(Self.smallFileLimit).download(from: keyURL, to: keyFile)

        let home = scratch.downloadDirectory.appending(path: "gnupg", directoryHint: .isDirectory)
        try GuestScratch.ensurePrivate(home)
        // Verifying needs no agent; without --no-autostart gpg leaves a gpg-agent daemon running on the temporary home.
        let common = ["--homedir", home.path, "--batch", "--no-tty", "--no-autostart"]
        let listing = try await gpgRun(gpg, common + ["--with-colons", "--show-keys", "--fingerprint", keyFile.path])
        let fingerprints = NetbootChecks.primaryFingerprints(inColonListing: listing.standardOutput)
        guard fingerprints == [AlpineNetboot.keyFingerprint] else {
            throw ToolError(
                "the key file holds \(fingerprints.isEmpty ? "no key" : fingerprints.joined(separator: ", ")); "
                    + "expected only \(AlpineNetboot.keyFingerprint); refusing it")
        }
        _ = try await gpgRun(gpg, common + ["--import", keyFile.path])
        let verdict = try await dependencies.run(
            CommandSpec(executable: gpg, arguments: common + ["--status-fd", "1", "--verify", signature.path, archive.path]))
        guard verdict.status == 0, NetbootChecks.isGoodSignature(fromStatus: verdict.standardOutput, by: AlpineNetboot.keyFingerprint)
        else {
            throw ToolError(
                "gpg does not report a good signature by \(AlpineNetboot.keyFingerprint) on \(archive.lastPathComponent); refusing it\n"
                    + verdict.standardError)
        }
        say("signature OK: made by the key \(AlpineNetboot.keyFingerprint)")
    }

    private func gpgRun(_ gpg: String, _ arguments: [String]) async throws -> CommandResult {
        let result = try await dependencies.run(CommandSpec(executable: gpg, arguments: arguments))
        guard result.succeeded else { throw ToolError("gpg \(arguments.last ?? "") failed: \(result.standardError)") }
        return result
    }

    private func unpack(_ archive: URL, into files: NetbootFiles) async throws {
        let listing = try await dependencies.run(CommandSpec(executable: "/usr/bin/tar", arguments: ["-tvzf", archive.path]))
        guard listing.succeeded else { throw ToolError("tar cannot read the archive: \(listing.standardError)") }
        let problems = NetbootChecks.problems(inTarListing: listing.standardOutput)
        guard problems.isEmpty else {
            throw ToolError("the archive is not safe to unpack:\n  " + problems.prefix(8).joined(separator: "\n  "))
        }
        let names = listing.standardOutput.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: " ", maxSplits: 8).last }
        for member in Self.members where !names.contains(where: { $0 == member }) {
            throw ToolError("the archive has no \(member)")
        }

        let staging = scratch.downloadDirectory.appending(path: "unpacked", directoryHint: .isDirectory)
        try GuestScratch.ensurePrivate(staging)
        let extraction = try await dependencies.run(
            CommandSpec(
                executable: "/usr/bin/tar",
                arguments: ["-xzf", archive.path, "-C", staging.path, "--no-same-owner"] + Self.members))
        guard extraction.succeeded else { throw ToolError("tar failed to unpack the archive: \(extraction.standardError)") }

        let fileManager = FileManager.default
        for member in Self.members {
            let source = staging.appending(path: member)
            let attributes = try fileManager.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ToolError("\(member) was not unpacked as a plain file")
            }
            let target = files.directory.appending(path: (member as NSString).lastPathComponent)
            try fileManager.moveItem(at: source, to: target)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        try? fileManager.removeItem(at: staging)

        try await ZbootKernel.extractImage(from: files.packagedKernel, to: files.kernel) { compressed in
            let result = try await dependencies.run(CommandSpec(executable: "/usr/bin/gzip", arguments: ["-d", "-f", compressed.path]))
            guard result.succeeded else { throw ToolError("gzip failed on the kernel: \(result.standardError)") }
        }
        try Data((files.version + "\n").utf8).write(to: files.releaseFile)
    }
}
