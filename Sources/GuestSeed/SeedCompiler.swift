// The provisioning library has no caller outside its tests until a later change attaches the seed to a machine, so a
// declaration only the tests reach is expected here; every other dead-code rule still applies.
// @dw:disable referenced-only-by-tests

import Foundation

/// Turns a checked spec into the text files of a cloud-init NoCloud seed. Every output is a function of its inputs alone:
/// the same spec, scripts and instance identifier give the same bytes.
package enum SeedCompiler {
    /// Where a step's script is unpacked and run in the guest: on the root file system, which allows running files, and
    /// under cloud-init's own folder, which every cloud image has. Not `/run`: Debian and Ubuntu mount it `noexec`.
    static let scriptDirectory = "/var/lib/cloud/vmrunner"

    /// The `meta-data` file: the identifier cloud-init keys its once-per-instance work on, and the guest's host name.
    static func metaData(name: String, instanceID: String) throws -> String {
        let allowed = instanceID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
        guard (1...64).contains(instanceID.utf8.count), allowed else {
            throw ProvisioningError(line: nil, "the instance identifier must be 1 to 64 ASCII letters, digits, ., _ or -")
        }
        return "instance-id: \(instanceID)\nlocal-hostname: \(name)\n"
    }

    /// The cloud-config made from the steps, in the spec's order: `bootcmd` for early-boot, `runcmd` for first-boot, and a
    /// file in cloud-init's per-boot folder for every-boot. A step this version cannot run is refused with its line.
    static func cloudConfig(for steps: [ProvisioningStep], scripts: VerifiedScripts) throws -> String {
        var bootcmd: [String] = []
        var runcmd: [String] = []
        var perBoot: [String] = []
        for (offset, step) in steps.enumerated() {
            let number = String(offset + 1)
            let label = "step-" + String(repeating: "0", count: max(0, 3 - number.count)) + number
            switch step.phase {
            case .earlyBoot:
                let run = try command(for: step, label: label, scripts: scripts)
                bootcmd.append("- ['/bin/sh', '-c', \(yamlQuoted(run))]")
            case .firstBoot:
                let run = try command(for: step, label: label, scripts: scripts)
                runcmd.append("- ['/bin/sh', '-c', \(yamlQuoted(run))]")
            case .everyBoot:
                let run = try command(for: step, label: label, scripts: scripts)
                let wrapper = Data("#!/bin/sh\n\(run)\n".utf8).base64EncodedString()
                perBoot.append(
                    "- path: /var/lib/cloud/scripts/per-boot/vmrunner-\(label)\n  permissions: '0700'\n  encoding: b64\n"
                        + "  content: '\(wrapper)'")
            case .preInstall, .postInstall, .installError:
                throw ProvisioningError(
                    line: step.line, "\(step.phase.rawValue) runs in an installer, and installer seed media are not built yet")
            case .ready, .preShutdown:
                throw ProvisioningError(line: step.line, "\(step.phase.rawValue) needs the guest agent, which is not built yet")
            }
        }
        var text = "#cloud-config\n"
        if !bootcmd.isEmpty { text += "bootcmd:\n" + bootcmd.joined(separator: "\n") + "\n" }
        if !runcmd.isEmpty { text += "runcmd:\n" + runcmd.joined(separator: "\n") + "\n" }
        if !perBoot.isEmpty { text += "write_files:\n" + perBoot.joined(separator: "\n") + "\n" }
        return text
    }

    /// A shell command that unpacks the step's script into `scriptDirectory` and runs it with the step's values. The script
    /// is base64 (letters, digits, `+`, `/`, `=`: nothing a shell or YAML reads specially); only the values are quoted.
    private static func command(for step: ProvisioningStep, label: String, scripts: VerifiedScripts) throws -> String {
        guard step.user == .system else {
            throw ProvisioningError(line: step.line, "a step that runs as the user needs the guest agent, which is not built yet")
        }
        guard step.secrets.isEmpty else {
            throw ProvisioningError(
                line: step.line, "a secret is delivered by the guest agent, which is not built yet; it is never written into the seed")
        }
        let bytes = try scriptBytes(of: step, scripts: scripts)
        let encoded = Data(bytes).base64EncodedString()
        let path = "\(scriptDirectory)/\(label)"
        let values = step.variables.map { " " + shellQuoted("\($0.name)=\($0.value)") }.joined()
        let unpack = "mkdir -p \(scriptDirectory) && printf %s \(encoded) | base64 -d > \(path)"
        return unpack + " && chmod 700 \(path) && exec env\(values) \(path)"
    }

    private static func scriptBytes(of step: ProvisioningStep, scripts: VerifiedScripts) throws -> [UInt8] {
        switch step.script {
        case .inline(let text):
            return Array(text.utf8)
        case .file(let path, _):
            guard let bytes = scripts.contents(of: path) else {
                throw ProvisioningError(line: step.line, "\(path) was not checked against its sha256")
            }
            guard bytes.starts(with: Array("#!".utf8)) else {
                throw ProvisioningError(line: step.line, "\(path) does not start with #! and its interpreter")
            }
            return bytes
        }
    }

    /// `text` in single quotes for a POSIX shell; a single quote inside becomes `'\''`.
    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }

    /// `text` as a YAML single-quoted scalar; a single quote inside is doubled.
    private static func yamlQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "''") + "'"
    }
}
