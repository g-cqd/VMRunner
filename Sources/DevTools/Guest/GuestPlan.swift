import Foundation
import VMHelperCore

/// What `vmr guest start` boots: the netboot image, two processors and 2 GiB at most, the framework's NAT, and a console.
///
/// Real-guest runs are capped (CONTRIBUTING.md, "Real-guest runs"), so the limits are checked here, before a descriptor
/// exists, and not left to the caller's care.
struct GuestPlan: Equatable {
    static let cpuRange = 1...2
    static let memoryRangeMiB = 512...2_048
    static let defaultMaximumSeconds = 900
    static let maximumSecondsLimit = 3_600

    var cpuCount = 2
    var memoryMiB = 2_048
    /// The kernel command line, or `nil` for the default of the release.
    var commandLine: String?

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
    }

    /// The Alpine init starts a getty on every `console=` device, and with `ip=dhcp` the NAT address is there before the
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
            network: .nat, console: .init(socket: scratch.socket.path))
    }
}
