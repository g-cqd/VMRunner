import Foundation
import NetPolicy
import VMHelperCore

/// The network policy a `filtered` descriptor names: the JSON the app stores for it, read when the machine starts and again
/// on each `policy` command.
enum PolicyFile {
    /// A real policy is a few kilobytes; the app's editor bounds every list.
    static let sizeLimit = 1 << 20

    /// The policy in the file at `path`, or the default policy when there is no path. A file that cannot be read or is not a
    /// policy is a failure with a message that names it.
    static func load(_ path: String?) throws -> NetworkPolicy {
        guard let path else { return NetworkPolicy() }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw HelperFailure.missingFile("the network policy \(path) does not exist, or the sandbox hides it")
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: sizeLimit + 1) ?? Data()
        } catch {
            throw HelperFailure.missingFile("the network policy \(path) cannot be read: \(error.localizedDescription)")
        }
        guard data.count <= sizeLimit else {
            throw HelperFailure.invalidDescriptor("the network policy \(path) is larger than \(sizeLimit) bytes")
        }
        do {
            return try JSONDecoder().decode(NetworkPolicy.self, from: data)
        } catch {
            throw HelperFailure.invalidDescriptor("the network policy \(path) is not a policy: \(error.localizedDescription)")
        }
    }
}
