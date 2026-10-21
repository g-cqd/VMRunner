import ContainerRunnerCore
import Foundation

/// Gets the pinned kernel into the scratch directory: download, check the archive's SHA-256, unpack the one member,
/// check the kernel's SHA-256. A kernel that is already there is checked again and never replaced.
///
/// This fetches one fixed HTTPS address and verifies it against a pinned checksum before using it. It does not go through
/// the app's download policy, because the app target cannot be imported without linking the app.
enum KernelProvider {
    static func ensureKernel(layout: RunnerLayout) async throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: layout.kernelImage.path) {
            try verify(layout.kernelImage, against: KernelArchive.imageSHA256)
            Console.line("kernel: \(layout.kernelImage.path) (already there, checksum ok)")
            return layout.kernelImage
        }

        try fileManager.createDirectory(at: layout.kernelArchive.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: layout.kernelArchive.path) {
            Console.line("kernel: downloading \(KernelArchive.urlString)")
            try await download(to: layout.kernelArchive)
        }
        try verify(layout.kernelArchive, against: KernelArchive.archiveSHA256)

        try? fileManager.removeItem(at: layout.kernelStaging)
        try fileManager.createDirectory(at: layout.kernelStaging, withIntermediateDirectories: true)
        try await unpack(layout: layout)
        try fileManager.createDirectory(at: layout.kernelImage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: KernelArchive.extractedMember(in: layout.kernelStaging), to: layout.kernelImage)
        try? fileManager.removeItem(at: layout.kernelStaging)
        try verify(layout.kernelImage, against: KernelArchive.imageSHA256)
        Console.line("kernel: \(layout.kernelImage.path) (unpacked, checksum ok)")
        return layout.kernelImage
    }

    /// Removes the file when it does not match, so the next run starts from a clean state instead of trusting it.
    private static func verify(_ file: URL, against expected: String) throws {
        do {
            try KernelArchive.verify(fileAt: file, expectedSHA256: expected)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw RunnerFailure("\(file.lastPathComponent): \(error); the file was removed")
        }
    }

    private static func download(to destination: URL) async throws {
        guard let url = URL(string: KernelArchive.urlString), url.scheme == "https" else {
            throw RunnerFailure("the pinned kernel address is not an HTTPS URL")
        }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RunnerFailure("the kernel download answered \((response as? HTTPURLResponse)?.statusCode ?? 0), not 200")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Unpacks only the one pinned kernel member into the staging directory.
    private static func unpack(layout: RunnerLayout) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = KernelArchive.extractionArguments(archive: layout.kernelArchive, directory: layout.kernelStaging)
        process.standardError = FileHandle.standardError
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw RunnerFailure("tar exited with status \(status) while unpacking the kernel") }
    }
}
