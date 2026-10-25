import Foundation

/// Signs the container runner ad hoc with the hardened runtime and `Resources/ContainerRunner.entitlements`, then verifies
/// the signature and reads the effective entitlements back, as `HelperBundler` does for the sandbox helper. Without
/// `com.apple.security.virtualization` the runner cannot start a virtual machine, so a file that does not grant it, or that
/// breaks `EntitlementPolicy`, is refused before anything is built or signed.
struct ContainerSigner {
    static let productName = "ContainerRunner"
    /// The package of its own the runner lives in, built into the scratch directory `vmr check build` uses for it.
    static let package = NestedPackage(path: "Packages/Containers")

    let root: URL
    /// An executable that is already built; `nil` builds the product first.
    let binary: URL?
    let configuration: AppBundler.Configuration
    /// Where the two result lines go; `vmr container-run` sends them to standard error, so that standard output stays the runner's.
    var report: (String) -> Void = { Output.out($0) }

    private var entitlementsURL: URL { root.appending(path: "Resources/\(Self.productName).entitlements") }

    /// Signs the runner where it is and returns it.
    @discardableResult
    func run() async throws -> URL {
        let expected = try checkedEntitlements()
        let target = try await executable()
        try await sign(target, expected: expected)
        return target
    }

    /// Copies `source` to `destination` (replacing what is there; `source` is left as it is) and signs the copy. `expected` comes
    /// from ``checkedEntitlements()``, which a caller runs before it builds anything.
    func install(_ source: URL, at destination: URL, expected: Entitlements.Dictionary) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        try await sign(destination, expected: expected)
    }

    /// The entitlements file's contents, once it grants virtualization and nothing outside ``EntitlementPolicy/runnerAllowed``.
    func checkedEntitlements() throws -> Entitlements.Dictionary {
        let expected = try Entitlements.load(fileAt: entitlementsURL)
        try verifyFile(expected)
        return expected
    }

    private func sign(_ target: URL, expected: Entitlements.Dictionary) async throws {
        try await BuildTools.codesign([
            "--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlementsURL.path, target.path,
        ])
        try await BuildTools.verifySignature(of: target)
        let effective = try await BuildTools.verifyEntitlements(
            of: target, expected: expected, isRelease: true, expectation: entitlementsURL.lastPathComponent)
        report("entitlements OK (\(effective.keys.sorted().joined(separator: ", ")))")
        report("Signed \(target.path)")
    }

    private func verifyFile(_ expected: Entitlements.Dictionary) throws {
        let file = entitlementsURL.lastPathComponent
        guard expected[Entitlements.virtualization] == .bool(true) else {
            throw ToolError("\(file) must grant \(Entitlements.virtualization): without it the runner cannot start a virtual machine")
        }
        let problems = EntitlementPolicy.problems(in: expected, isRelease: true, allowing: EntitlementPolicy.runnerAllowed)
        guard problems.isEmpty else {
            Output.err("entitlement policy FAILED:")
            for problem in problems {
                Output.err("  - \(file): \(problem)")
            }
            throw ToolError("\(file) breaks the policy in EntitlementPolicy.swift; nothing was built")
        }
    }

    /// The `binary` given, or the product built in `configuration`.
    func executable() async throws -> URL {
        let target: URL
        if let binary {
            target = binary
        } else {
            let arguments = Self.package.selection(in: root) + ["-c", configuration.rawValue, "--product", Self.productName]
            target = try await BuildTools.build(arguments).appending(path: Self.productName)
        }
        guard FileManager.default.isExecutableFile(atPath: target.path) else { throw ToolError("\(target.path) is not an executable") }
        return target
    }
}
