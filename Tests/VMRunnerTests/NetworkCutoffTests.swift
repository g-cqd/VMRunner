import Foundation
import NetPolicy
import TestKit
import Testing
import Virtualization

@testable import VMRunner

/// The kill switch's settings: the VPN rule and the metered-network switch, stored with a tolerant decode, left alone by
/// the profiles, listed in the exposure summary while the machine has a network card, and explained in the help.
struct NetworkCutoffSettingsTests {
    private func isCutoffLine(_ exposure: Exposure) -> Bool {
        exposure.text.contains("Kill switch") || exposure.text.contains("Low Data Mode")
    }

    @Test func bothRulesAreOffForANewMachineAndForAConfigWrittenBeforeThem() throws {
        let fresh = VMConfig.new(name: "n", guest: .linux)
        #expect(fresh.networkPolicy.vpn == .ignore && !fresh.networkCutsOnMeteredPath)
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32}"#
        let decoded = try VMConfig.decode(from: Data(old.utf8))
        #expect(decoded.networkPolicy.vpn == .ignore && !decoded.networkCutsOnMeteredPath)
    }

    @Test func theRulesAreStoredAndReadBack() throws {
        var config = VMConfig.new(name: "k", guest: .linux)
        config.networkPolicy.vpn = .required
        config.networkCutsOnMeteredPath = true
        let decoded = try VMConfig.decode(from: config.encoded())
        #expect(decoded.networkPolicy.vpn == .required && decoded.networkCutsOnMeteredPath)
    }

    @Test func theSummaryNamesEachRuleWhileTheMachineHasANetworkCard() {
        var config = VMConfig.new(name: "k", guest: .linux)
        #expect(!config.exposures.contains(where: isCutoffLine))
        config.networkPolicy.vpn = .required
        config.networkCutsOnMeteredPath = true
        let lines = config.exposures.filter(isCutoffLine)
        #expect(
            lines.map(\.text) == [
                "Kill switch: the network is cut while no VPN is up on this Mac.",
                "The network is cut while this Mac's connection is metered or in Low Data Mode.",
            ])
        #expect(lines.allSatisfy { $0.level == .none })
        config.networkMode = .none
        #expect(!config.exposures.contains(where: isCutoffLine))
    }

    @Test(arguments: SecurityProfile.allCases)
    func profilesLeaveTheRulesAlone(profile: SecurityProfile) {
        var config = VMConfig.new(name: "k", guest: .linux)
        config.networkPolicy.vpn = .forbidden
        config.networkCutsOnMeteredPath = true
        let applied = config.applying(profile)
        #expect(applied.networkPolicy.vpn == .forbidden && applied.networkCutsOnMeteredPath)
        #expect(applied.detectedProfile == profile)
    }

    @Test func theHelpExplainsBothRulesAndWhatTheyWatch() {
        let entry = HelpTopic.killSwitch.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        for phrase in ["Required", "Forbidden", "Low Data Mode", "not the guest", "Network cut"] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
        #expect(HelpTopic.guestVpn.entry.related.contains(.killSwitch))
    }
}

/// The kill switch's rules: the VPN rule first, an unknown VPN state breaking both VPN rules, then the metered switch.
struct NetworkCutoffRuleTests {
    @Test func theVPNRuleDecidesFirstAndAnUnknownStateBreaksIt() {
        var config = VMConfig.new(name: "k", guest: .linux)
        #expect(!config.hasNetworkCutoff)
        #expect(config.networkCutoffReason(on: HostNetworkPath()) == nil, "no rule, nothing to cut")
        config.networkPolicy.vpn = .required
        #expect(config.hasNetworkCutoff)
        #expect(config.networkCutoffReason(on: HostNetworkPath(vpn: .unknown)) == .vpnRequired)
        #expect(config.networkCutoffReason(on: HostNetworkPath(vpn: .inactive)) == .vpnRequired)
        #expect(config.networkCutoffReason(on: HostNetworkPath(vpn: .active)) == nil)
        config.networkPolicy.vpn = .forbidden
        #expect(config.networkCutoffReason(on: HostNetworkPath(vpn: .active)) == .vpnForbidden)
        #expect(config.networkCutoffReason(on: HostNetworkPath(vpn: .unknown)) == .vpnForbidden)
        #expect(config.networkCutoffReason(on: HostNetworkPath(vpn: .inactive)) == nil)
    }

    @Test func theMeteredSwitchCutsAnExpensiveOrConstrainedPathOnly() {
        var config = VMConfig.new(name: "k", guest: .linux)
        config.networkCutsOnMeteredPath = true
        #expect(config.hasNetworkCutoff)
        #expect(config.networkCutoffReason(on: HostNetworkPath(vpn: .inactive)) == nil)
        #expect(config.networkCutoffReason(on: HostNetworkPath(vpn: .inactive, isExpensive: true)) == .meteredPath)
        #expect(config.networkCutoffReason(on: HostNetworkPath(vpn: .inactive, isConstrained: true)) == .meteredPath)
    }

    @Test func aMachineWithoutANetworkCardHasNothingToCut() {
        var config = VMConfig.new(name: "k", guest: .linux)
        config.networkPolicy.vpn = .required
        config.networkCutsOnMeteredPath = true
        config.networkMode = .none
        #expect(!config.hasNetworkCutoff)
        #expect(config.networkCutoffReason(on: HostNetworkPath()) == nil)
    }
}

/// The watcher: it cuts at once when an unknown path breaks a rule, and calls `connect` only when the answer changes.
@MainActor
struct NetworkCutoffWatchTests {
    private func machine(_ vpn: VPNRequirement, metered: Bool = false) -> VMConfig {
        var config = VMConfig.new(name: "k", guest: .linux)
        config.networkPolicy.vpn = vpn
        config.networkCutsOnMeteredPath = metered
        return config
    }

    @Test func aRequiredVPNCutsTheCardUntilOneIsUpAndAgainWhenItGoes() async throws {
        let (paths, feed) = AsyncStream.makeStream(of: HostNetworkPath.self)
        let cutoff = NetworkCutoff(config: machine(.required), source: { paths })
        let calls = AsyncEventProbe<Bool>()
        cutoff.start { calls.record($0) }
        #expect(calls.events == [false], "an unknown VPN state cuts the card before the first sample")
        #expect(cutoff.reason == .vpnRequired)

        feed.yield(HostNetworkPath(vpn: .active))
        _ = try await calls.wait(forAtLeast: 2)
        #expect(cutoff.reason == nil)
        feed.yield(HostNetworkPath(vpn: .active, isExpensive: true))
        feed.yield(HostNetworkPath(vpn: .inactive))
        _ = try await calls.wait(forAtLeast: 3)
        #expect(calls.events == [false, true, false], "a sample that changes nothing calls nothing")
        #expect(cutoff.reason == .vpnRequired)
        feed.finish()
    }

    @Test func aMeteredOrLowDataPathCutsTheCardWhenTheSwitchIsOn() async throws {
        let (paths, feed) = AsyncStream.makeStream(of: HostNetworkPath.self)
        let cutoff = NetworkCutoff(config: machine(.ignore, metered: true), source: { paths })
        let calls = AsyncEventProbe<Bool>()
        cutoff.start { calls.record($0) }
        #expect(calls.events.isEmpty, "an unknown path is not a metered one")
        feed.yield(HostNetworkPath(vpn: .inactive, isConstrained: true))
        _ = try await calls.wait(forAtLeast: 1)
        #expect(cutoff.reason == .meteredPath)
        feed.yield(HostNetworkPath(vpn: .inactive))
        _ = try await calls.wait(forAtLeast: 2)
        #expect(calls.events == [false, true])
        feed.finish()
    }
}

/// What the toolbar reads: no cut for a machine without a kill switch, and a reason that says what cut the network.
@MainActor
struct NetworkCutoffIndicatorTests {
    @Test func aMachineWithoutAKillSwitchShowsNoCut() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        await rig.start()
        #expect(rig.controller.guest?.networkCutoff == nil)
        #expect(rig.library.model(for: rig.id).networkCutoff == nil)
        guest.powerOff()
        rig.expectReleased()
    }

    @Test func eachReasonSaysWhatCutTheNetwork() {
        #expect(NetworkCutoffReason.vpnRequired.text.contains("needs a VPN"))
        #expect(NetworkCutoffReason.vpnForbidden.text.contains("must not use"))
        #expect(NetworkCutoffReason.meteredPath.text.contains("Low Data Mode"))
    }
}

/// The cable the kill switch pulls: the same attachment goes back, and a pull the card refuses is reported, never assumed.
@MainActor
struct NetworkCardCableTests {
    /// A card whose attachment the test controls; `refusesDetach` makes it keep its attachment, as a refused change would.
    @MainActor
    private final class FakeCard: NetworkCard {
        var refusesDetach = false
        private var current: VZNetworkDeviceAttachment?

        init(_ attachment: VZNetworkDeviceAttachment?) { current = attachment }

        var attachment: VZNetworkDeviceAttachment? {
            get { current }
            set { if newValue != nil || !refusesDetach { current = newValue } }
        }
    }

    @Test func aPulledCableIsPluggedBackWithTheSameAttachment() {
        let nat = VZNATNetworkDeviceAttachment()
        let card = FakeCard(nat)
        var cable = NetworkCardCable()
        let pulled = cable.set(card, connected: false)
        #expect(pulled)
        #expect(card.attachment == nil)
        let pluggedBack = cable.set(card, connected: true)
        #expect(pluggedBack)
        #expect(card.attachment === nat)
    }

    @Test func aPullTheCardRefusesIsReportedSoTheMachineCanBeStopped() {
        let nat = VZNATNetworkDeviceAttachment()
        let card = FakeCard(nat)
        card.refusesDetach = true
        var cable = NetworkCardCable()
        let pulled = cable.set(card, connected: false)
        #expect(!pulled, "the card is still connected")
        #expect(card.attachment === nat)
    }

    @Test func theHelpSaysAMachineWhoseCardStaysConnectedIsStopped() {
        #expect(HelpTopic.killSwitch.entry.advanced.joined(separator: " ").contains("VMRunner stops the machine"))
    }
}
