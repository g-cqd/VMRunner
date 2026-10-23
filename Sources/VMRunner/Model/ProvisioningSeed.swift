import Foundation
import GuestSeed

/// Why a machine's provisioning spec could not become a seed, in the words a failed start shows.
struct ProvisioningSeedError: LocalizedError, Equatable {
    /// The spec's file name.
    let spec: String
    /// What is wrong, starting with the spec's line when the problem has one ("line 7: ...").
    let reason: String

    var errorDescription: String? {
        "The provisioning spec \(spec) can't be used: \(reason). "
            + "Fix it, or remove it in the machine's settings to start without it."
    }
}

/// A Linux machine's cloud-init seed (ADR-0012): compiled at each start from the provisioning spec and its script files as
/// they are at that moment, written into the machine's bundle readable by its owner only, attached read-only, and removed
/// with the run's other leftovers when the machine stops.
enum ProvisioningSeed {
    /// The spec at `path`, read and checked, with the seed it compiles to. Every script file it names is read from the spec's
    /// folder and must match its SHA-256. Nothing is written. A refusal names the spec, and its line when there is one.
    static func compile(specAt path: String, instanceID: String) throws -> (spec: ProvisioningSpec, seed: CloudInitSeed) {
        let url = URL(filePath: path)
        do {
            let spec = try ProvisioningSpec(parsing: try readSpec(at: url))
            let scripts = try ScriptFiles.verify(spec, in: url.deletingLastPathComponent())
            let seed = try SeedCompiler.compile(spec, scripts: scripts, instanceID: instanceID)
            return (spec, seed)
        } catch let error as ProvisioningError {
            throw ProvisioningSeedError(spec: url.lastPathComponent, reason: error.description)
        }
    }

    /// Builds this start's seed into `bundle` when the machine has a spec in use, and removes the last one otherwise. It runs
    /// before the machine is configured, so the seed is the spec and its scripts as they are now.
    static func prepare(for config: VMConfig, bundle: VMBundle) throws {
        bundle.remove(bundle.provisioningSeed)
        guard let path = config.activeProvisioningSpecPath else { return }
        let seed = try compile(specAt: path, instanceID: config.id.uuidString).seed
        try SeedImage.write(seed, to: bundle.provisioningSeed)
    }

    /// The spec's text: a regular file of at most `ProvisioningLimits.standard.maxSpecBytes` bytes of UTF-8. One byte more
    /// than the limit is read, so a huge file is never read whole.
    private static func readSpec(at url: URL) throws -> String {
        let name = url.lastPathComponent
        let limit = ProvisioningLimits.standard.maxSpecBytes
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw ProvisioningSeedError(spec: name, reason: "it is missing or not a regular file")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ProvisioningSeedError(spec: name, reason: "it cannot be read")
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        guard data.count <= limit else { throw ProvisioningSeedError(spec: name, reason: "it is larger than \(limit) bytes") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProvisioningSeedError(spec: name, reason: "it is not UTF-8 text")
        }
        return text
    }
}
