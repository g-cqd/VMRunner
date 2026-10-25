import Testing
import Virtualization

@testable import PrivateInterfaces

/// The performance-monitoring switch against this Mac's framework. These tests need the framework's private selectors, so
/// they are skipped (not failed) on a macOS that does not have them; the fail-closed paths are covered without them in
/// `CapabilityStatusTests` and `CapabilityApplyTests`. Nothing here starts a virtual machine.
struct PMUContractTests {
    private static let resolver = RuntimeMethodResolver()
    private static let platform = "VZGenericPlatformConfiguration"

    /// Selectors the framework has next to the switch. They are listed so a macOS build's record shows what it offered; none is
    /// registered and none is ever called.
    private static let seen: [(className: String, selector: String)] = [
        (platform, "_setPerformanceMonitoringUnitEmulationEnabled:"), (platform, "_performanceMonitoringUnitEmulationEnabled"),
        (platform, "_setFineGrainedTrapsEmulationEnabled:"), (platform, "_fineGrainTrapsEmulationEnabled"),
        (platform, "_setVirtualizationHostExtensionEnabled:"), (platform, "_virtualizationHostExtensionEnabled"),
        (platform, "_setGuestType:"), (platform, "_guestType"),
        ("VZEFIBootLoader", "_setROMImageURL:"), ("VZEFIBootLoader", "_ROMImageURL"),
    ]

    static let switchSelectorsExist: Bool = [PMUEmulation.entry.setter, PMUEmulation.entry.getter].allSatisfy {
        if case .found = resolver.lookup(className: $0.className, selector: $0.selector) { true } else { false }
    }

    static let hostBuildIsVerified: Bool = OSBuild.running.flatMap { OSBuild($0) }.map { PMUEmulation.entry.builds.contains($0) } ?? false

    @Test(.enabled(if: switchSelectorsExist, "this macOS has no performance-monitoring selectors on the generic platform"))
    func theSelectorsHaveTheEncodingsTheRegistryDeclares() {
        var record = "kern.osversion \(OSBuild.running ?? "unreadable"); selectors found (class, selector, answer):\n"
        for (className, selector) in Self.seen {
            record += "\(className) \(selector) \(Self.resolver.lookup(className: className, selector: selector))\n"
        }
        Attachment.record(record, named: "selectors.txt")
        for method in [PMUEmulation.entry.setter, PMUEmulation.entry.getter] {
            guard case .found(let encoding) = Self.resolver.lookup(className: method.className, selector: method.selector) else {
                Issue.record("\(method.selector) vanished between two lookups")
                continue
            }
            #expect(String(encoding.filter { !$0.isNumber }) == method.encoding, "\(method.selector) is \(encoding)")
        }
    }

    @Test(.enabled(if: hostBuildIsVerified, "needs a build the registry was verified on; there the selectors must exist"))
    func aFreshConfigurationTakesTheSwitchAndKeepsIt() {
        #expect(PMUEmulation.status() == .available)
        let configuration = VZGenericPlatformConfiguration()
        #expect(PMUEmulation.apply(to: configuration) == .available)
        #expect(PMUEmulation.entry.apply(false, to: configuration, in: .current()) == .available, "and it can be set back")
    }

    @Test
    func theKillSwitchStopsTheRealCapabilityBeforeAnyLookup() {
        let killed = PrivateCapabilityContext.current(killed: [.performanceMonitoringEmulation])
        #expect(PMUEmulation.status(in: killed) == .unavailable(.killSwitch))
        #expect(PMUEmulation.apply(to: VZGenericPlatformConfiguration(), in: killed) == .unavailable(.killSwitch))
    }

    @Test
    func theRegisteredBuildsAreThoseOfDarwin26() {
        #expect(PMUEmulation.entry.builds.contains(OSBuild(major: 26, letter: "A", count: 434)))
        #expect(!PMUEmulation.entry.builds.contains(OSBuild(major: 25, letter: "H", count: 100)))
        #expect(!PMUEmulation.entry.builds.contains(OSBuild(major: 27, letter: "A", count: 1)))
        #expect(CapabilityRegistry.standard.entries.keys.contains(.performanceMonitoringEmulation))
    }
}
