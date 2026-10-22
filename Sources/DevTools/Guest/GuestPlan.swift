import Foundation
import VMHelperCore

/// What `vmr guest start` boots: the netboot image, two processors and 2 GiB at most, the framework's NAT or the app's
/// filtered network, and a console.
///
/// Real-guest runs are capped (CONTRIBUTING.md, "Real-guest runs"), so the limits are checked here, before a descriptor
/// exists, and not left to the caller's care.
struct GuestPlan: Equatable {
    static let cpuRange = 1...2
    static let memoryRangeMiB = 512...2_048
    static let defaultMaximumSeconds = 900
    static let maximumSecondsLimit = 3_600
    /// The largest policy file taken; the helper's own limit is the same.
    static let policyLimit = 1 << 20

    var cpuCount = 2
    var memoryMiB = 2_048
    /// The kernel command line, or `nil` for the default of the release.
    var commandLine: String?
    /// `nat` (the framework's NAT, the default) or `filtered` (the app's user-mode stack, judged by a policy).
    var network = HelperDescriptor.Network.nat
    /// The policy file of a filtered network, or `nil` for the default policy.
    var policyFile: URL?
    var denyAction = HelperDescriptor.DenyAction.reset

    func validate() throws {
        guard Self.cpuRange.contains(cpuCount) else {
            throw ToolError.usage("--cpus must be from \(Self.cpuRange.lowerBound) to \(Self.cpuRange.upperBound), not \(cpuCount)")
        }
        guard Self.memoryRangeMiB.contains(memoryMiB) else {
            throw ToolError.usage(
                "--memory-mib must be from \(Self.memoryRangeMiB.lowerBound) to \(Self.memoryRangeMiB.upperBound), not \(memoryMiB)")
        }
        if let commandLine {
            guard !commandLine.isEmpty, !commandLine.contains(where: \.isNewline) else {
                throw ToolError.usage("--command-line must be one non-empty line")
            }
        }
        guard network == .nat || network == .filtered else {
            throw ToolError.usage("--net must be nat or filtered")
        }
        guard network == .filtered || (policyFile == nil && denyAction == .reset) else {
            throw ToolError.usage("--policy and --deny-action belong to --net filtered")
        }
    }

    /// The text of a policy file that a helper will accept as one: a JSON object, at most ``policyLimit`` bytes. The helper
    /// reads the fields; this only keeps a wrong file from reaching it.
    static func policyText(of file: URL) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ToolError("cannot read the policy file \(file.path): \(error.localizedDescription)")
        }
        guard data.count <= policyLimit else { throw ToolError("the policy file \(file.path) is larger than \(policyLimit) bytes") }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw ToolError("the policy file \(file.path) is not a JSON object")
        }
        return data
    }

    /// The Alpine init starts a getty on every `console=` device, and with `ip=dhcp` the guest's address is there before the
    /// packages are fetched from the release's repository (`alpine_repo`), which builds the root file system in memory.
    static func defaultCommandLine(release: String) -> String {
        let parts = release.split(separator: ".")
        let series = parts.count >= 2 ? "v\(parts[0]).\(parts[1])" : "latest-stable"
        let mirror = "https://\(AlpineNetboot.host)/alpine/\(series)"
        return "console=hvc0 ip=dhcp alpine_repo=\(mirror)/main modloop=\(mirror)/releases/aarch64/netboot-\(release)/modloop-virt"
    }

    func descriptor(files: NetbootFiles, scratch: GuestScratch) throws -> HelperDescriptor {
        try validate()
        return HelperDescriptor(
            name: "vmr-guest", cpuCount: cpuCount, memoryMiB: memoryMiB,
            boot: .init(
                kind: .kernel, kernel: files.kernel.path, initrd: files.initramfs.path,
                commandLine: commandLine ?? Self.defaultCommandLine(release: files.version)),
            network: network, console: .init(socket: scratch.socket.path),
            networkPolicy: network == .filtered ? scratch.policyFile.path : nil, denyAction: denyAction)
    }
}
