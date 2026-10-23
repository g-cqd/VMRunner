// The provisioning library has no caller outside its tests until a later change attaches the seed to a machine, so a
// declaration only the tests reach is expected here; every other dead-code rule still applies.
// @dw:disable referenced-only-by-tests

/// The text files of a cloud-init NoCloud seed. Only `SeedCompiler.compile` makes one, from a spec whose script files were
/// checked. Every field is text the guest may read: the seed holds no secret, and no field can hold one.
package struct CloudInitSeed: Equatable, Sendable {
    package let userData: String
    package let metaData: String
    /// The `network-config` file, when the spec gives `networkData`.
    package let networkConfig: String?
}

extension SeedCompiler {
    /// The MIME boundary between the parts of a `user-data` that holds both the spec's own data and the steps.
    static let boundary = "==vmrunner-seed-boundary=="

    /// The seed for `spec`, refusing with the spec's line anything this version cannot carry.
    package static func compile(_ spec: ProvisioningSpec, scripts: VerifiedScripts, instanceID: String) throws -> CloudInitSeed {
        let metaData = try Self.metaData(name: spec.name, instanceID: instanceID)
        var steps: String?
        if !spec.steps.isEmpty { steps = try cloudConfig(for: spec.steps, scripts: scripts) }
        let userData: String
        switch (spec.cloudInit.userData, steps) {
        case (let given?, let steps?):
            userData = try multipart(given, steps: steps)
        case (let given?, nil):
            _ = try partType(of: given)
            userData = given.text
        case (nil, let steps?):
            userData = steps
        case (nil, nil):
            userData = "#cloud-config\n"
        }
        return CloudInitSeed(userData: userData, metaData: metaData, networkConfig: spec.cloudInit.networkData?.text)
    }

    /// The MIME type cloud-init gives the spec's own user data, read from its first line; other kinds are refused.
    private static func partType(of given: SpecText) throws -> String {
        // `#cloud-config-archive` and `#cloud-config-jsonp` are other part kinds that begin with the same words.
        if given.text.hasPrefix("#cloud-config"), given.text.dropFirst("#cloud-config".count).first != "-" {
            return "text/cloud-config"
        }
        if given.text.hasPrefix("#!") { return "text/x-shellscript" }
        throw ProvisioningError(line: given.line, "cloudInit.userData must start with #cloud-config or #!")
    }

    /// The user's part, then the steps' cloud-config, which appends its lists to the user's instead of replacing them.
    private static func multipart(_ given: SpecText, steps: String) throws -> String {
        let type = try partType(of: given)
        guard !given.text.contains(boundary) else {
            throw ProvisioningError(line: given.line, "cloudInit.userData contains the seed's MIME boundary \(boundary)")
        }
        let userPart = given.text.hasSuffix("\n") ? given.text : given.text + "\n"
        var text = "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\nMIME-Version: 1.0\n\n"
        text += "--\(boundary)\nContent-Type: \(type); charset=\"utf-8\"\n\n" + userPart
        text += "--\(boundary)\nContent-Type: text/cloud-config; charset=\"utf-8\"\n"
        text += "Merge-Type: list(append)+dict(no_replace,recurse_list)+str()\n\n" + steps
        text += "--\(boundary)--\n"
        return text
    }
}
