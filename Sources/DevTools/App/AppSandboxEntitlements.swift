import Foundation
import VMHelperKit

/// The entitlements of the App Sandbox helper bundle: the checked-in base file, plus what this run's grants need.
///
/// Files outside the container are reached through temporary-exception entitlements that name each absolute path. They
/// are the simplest way that works for a helper launched from the command line: a file descriptor cannot carry a disk to
/// the framework (its attachments take URLs), and a security-scoped bookmark is bound to the app that made it, so the
/// unsandboxed launcher cannot hand one to a differently signed helper. The price is that the grants live in the
/// signature, so the bundle is signed again for every descriptor (ad hoc, a few milliseconds), and that the entitlement is
/// not available to a Mac App Store build, which the app is not.
enum AppSandboxEntitlements {
    static let networkClient = "com.apple.security.network.client"
    static let readOnlyPaths = "com.apple.security.temporary-exception.files.absolute-path.read-only"
    static let readWritePaths = "com.apple.security.temporary-exception.files.absolute-path.read-write"

    /// `base` with the network entitlement and the path exceptions `grants` ask for.
    static func entitlements(base: Entitlements.Dictionary, grants: SandboxGrants) -> Entitlements.Dictionary {
        var entitlements = base
        if grants.hostSockets { entitlements[networkClient] = .bool(true) }
        if !grants.read.isEmpty { entitlements[readOnlyPaths] = .array(grants.read.map(PlistValue.string)) }
        if !grants.readWrite.isEmpty { entitlements[readWritePaths] = .array(grants.readWrite.map(PlistValue.string)) }
        return entitlements
    }

    /// The entitlements as the XML property list `codesign --entitlements` reads.
    static func propertyList(_ entitlements: Entitlements.Dictionary) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: entitlements.mapValues(\.propertyListObject), format: .xml, options: 0)
        } catch {
            throw ToolError("cannot write the entitlements property list: \(error)")
        }
    }
}

extension PlistValue {
    /// The value as the Foundation object `PropertyListSerialization` takes.
    fileprivate var propertyListObject: Any {
        switch self {
        case .bool(let value): value
        case .integer(let value): value
        case .real(let value): value
        case .string(let value): value
        case .data(let value): value
        case .date(let value): value
        case .array(let values): values.map(\.propertyListObject)
        case .dictionary(let values): values.mapValues(\.propertyListObject)
        }
    }
}
