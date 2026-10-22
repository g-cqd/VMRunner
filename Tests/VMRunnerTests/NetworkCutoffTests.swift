import Foundation
import NetPolicy
import Testing

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
