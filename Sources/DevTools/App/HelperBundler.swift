import Foundation
import VMHelperCore

/// Builds the sandbox helper's helper and signs it ad hoc for an engine, then reads the entitlements back from the signed
/// result, as `AppBundler` does for the app.
///
/// Two artifacts come out under `build/sandbox/`: the plain helper signed with the virtualization entitlement only
/// (engines `none` and `seatbelt`), and `VMHelper.app`, a bundle signed with `app-sandbox`, `virtualization` and the grants
/// of one descriptor (engine `app-sandbox`).
struct HelperBundler {
    static let productName = "VMHelper"

    let root: URL
    let configuration: AppBundler.Configuration
    /// A helper binary built already, used instead of building one.
    let prebuilt: URL?

    var workDirectory: URL { root.appending(path: "build/sandbox", directoryHint: .isDirectory) }
    private var plainEntitlementsURL: URL { root.appending(path: "Resources/\(Self.productName).entitlements") }
    private var appSandboxEntitlementsURL: URL { root.appending(path: "Resources/\(Self.productName).appsandbox.entitlements") }
    private var infoPlistURL: URL { root.appending(path: "Resources/\(Self.productName).Info.plist") }

    /// Where `plainHelper` puts the helper, which is also the path a Seatbelt profile lets `sandbox-exec` execute.
    var plainHelperURL: URL { workDirectory.appending(path: "plain/\(Self.productName)") }
    var appBundleURL: URL { workDirectory.appending(path: "\(Self.productName).app", directoryHint: .isDirectory) }

    // MARK: Build

    /// The unsigned helper binary: the `prebuilt` one, or the product built in `configuration`.
    func binary() async throws -> URL {
        if let prebuilt {
            guard FileManager.default.isExecutableFile(atPath: prebuilt.path) else {
                throw ToolError("\(prebuilt.path) is not an executable")
            }
            return prebuilt
        }
        let arguments = ["--package-path", root.path, "-c", configuration.rawValue, "--product", Self.productName]
        return try await BuildTools.build(arguments).appending(path: Self.productName)
    }

    // MARK: Plain helper

    /// A copy of `binary` signed with the virtualization entitlement only.
    func plainHelper(from binary: URL) async throws -> URL {
        let directory = plainHelperURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: plainHelperURL)
        let expected = try Entitlements.load(fileAt: plainEntitlementsURL)
        try await sign(plainHelperURL, entitlementsFile: plainEntitlementsURL, expected: expected)
        return plainHelperURL
    }

    // MARK: App Sandbox bundle

    /// `VMHelper.app` signed with the base App Sandbox entitlements plus what `grants` need; returns its executable.
    func appSandboxHelper(from binary: URL, grants: SandboxGrants) async throws -> URL {
        try BuildTools.assemble(bundle: appBundleURL, executable: Self.productName, binary: binary, infoPlist: infoPlistURL)
        let expected = AppSandboxEntitlements.entitlements(base: try Entitlements.load(fileAt: appSandboxEntitlementsURL), grants: grants)
        let entitlementsFile = workDirectory.appending(path: "\(Self.productName).generated.entitlements")
        try AppSandboxEntitlements.propertyList(expected).write(to: entitlementsFile)
        try await sign(appBundleURL, entitlementsFile: entitlementsFile, expected: expected)
        return appBundleURL.appending(path: "Contents/MacOS/\(Self.productName)")
    }

    // MARK: Signing

    /// Signs ad hoc with the hardened runtime, then checks the signature and that the effective entitlements, read back,
    /// equal `expected`: nothing added, nothing dropped, never `get-task-allow`.
    private func sign(_ url: URL, entitlementsFile: URL, expected: Entitlements.Dictionary) async throws {
        try await BuildTools.codesign(["--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlementsFile.path, url.path])
        try await BuildTools.verifySignature(of: url)
        let effective = try await BuildTools.verifyEntitlements(
            of: url, expected: expected, isRelease: true, expectation: "what \(url.lastPathComponent) was signed with")
        Output.out("entitlements OK for \(url.lastPathComponent) (\(effective.keys.sorted().joined(separator: ", ")))")
    }
}
