import CryptoKit
package import Foundation

/// The contents of every `file:` step of a spec, each read once and found to match the SHA-256 the spec gives. Only
/// `ScriptFiles.verify` makes one, so a seed is never built from a file nobody checked.
package struct VerifiedScripts: Sendable {
    /// A check covers a path and the digest it was checked against: the same path under another digest is not covered.
    fileprivate struct Key: Hashable, Sendable {
        let path: String
        let sha256: String
    }

    private let files: [Key: [UInt8]]

    fileprivate init(files: [Key: [UInt8]]) {
        self.files = files
    }

    /// The checked bytes of the file a step names by `path` and `sha256`, or nil when no check covered that pair.
    func contents(of path: String, sha256: String) -> [UInt8]? {
        files[Key(path: path, sha256: sha256)]
    }
}

/// The host's check of a spec's script files, before anything is packed into a seed (ADR-0012, item 5). It fails closed:
/// the first file that is missing, not a regular file, reached through a symbolic link, larger than the limit or different
/// from its SHA-256 refuses the whole spec. The bytes it hashes are the bytes it returns, read once. A file swapped for a
/// link between the type check and the read is not refused as a link, but only bytes that match the digest are returned.
package enum ScriptFiles {
    package static func verify(
        _ spec: ProvisioningSpec, in directory: URL, limits: ProvisioningLimits = .standard
    ) throws -> VerifiedScripts {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        var contents: [VerifiedScripts.Key: [UInt8]] = [:]
        for step in spec.steps {
            guard case .file(let path, let sha256) = step.script else { continue }
            let bytes = try read(path, in: base, line: step.line, limits: limits)
            let actual = SHA256.hash(data: bytes).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
            guard actual == sha256 else {
                throw ProvisioningError(
                    line: step.line, "\(path) does not match its sha256: the spec says \(sha256), the file is \(actual)")
            }
            contents[VerifiedScripts.Key(path: path, sha256: sha256)] = bytes
        }
        return VerifiedScripts(files: contents)
    }

    private static func read(_ path: String, in base: URL, line: Int, limits: ProvisioningLimits) throws -> [UInt8] {
        let file = base.appending(path: path)
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { throw ProvisioningError(line: line, "\(path) is a symbolic link") }
        guard values?.isRegularFile == true else { throw ProvisioningError(line: line, "\(path) is not a regular file") }
        guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path else {
            throw ProvisioningError(line: line, "\(path) goes through a symbolic link")
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw ProvisioningError(line: line, "cannot read \(path)") }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limits.maxFileBytes + 1)) ?? Data()
        guard data.count <= limits.maxFileBytes else {
            throw ProvisioningError(line: line, "\(path) is larger than \(limits.maxFileBytes) bytes")
        }
        return [UInt8](data)
    }
}
