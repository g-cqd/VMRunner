import Foundation
import Testing

@testable import VMRunner

struct NetworkConfigTests {
    @Test func aConfigWrittenBeforeFilteredNetworkingLoadsWithDefaults() throws {
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"#
            + #""diskGiB":32,"networkMode":"nat","macAddress":"02:00:00:00:00:01"}"#

        let config = try VMConfig.decode(from: Data(old.utf8))

        #expect(config.networkMode == .nat)
        #expect(config.macAddress == "02:00:00:00:00:01")
        #expect(config.networkPolicy == NetworkPolicy())
        #expect(config.networkPolicy.blockPrivateRanges)
        #expect(config.networkPolicy.mode == .denyListed)
        #expect(config.networkDenyAction == .reset)
        #expect(config.networkResetsOnHostChange)
    }

    @Test func aPartialPolicyKeepsWhatItSaysAndDefaultsTheRest() throws {
        let stored =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"m","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32,"#
            + #""networkMode":"filtered","networkPolicy":{"mode":"allowListed","allowedDomains":["*.example.com"]}}"#

        let config = try VMConfig.decode(from: Data(stored.utf8))

        #expect(config.networkMode == .filtered)
        #expect(config.networkPolicy.mode == .allowListed)
        #expect(config.networkPolicy.rules(in: .allowedDomains) == ["*.example.com"])
        #expect(config.networkPolicy.blockPrivateRanges)
        #expect(config.networkPolicy.blockedPorts.isEmpty)
    }

    @Test func aFilteredConfigRoundTripsWithEveryOption() throws {
        var config = VMConfig.new(name: "f", guest: .linux)
        config.networkMode = .filtered
        config.networkDenyAction = .drop
        config.networkResetsOnHostChange = false
        config.networkPolicy.mode = .allowListed
        config.networkPolicy.blockPrivateRanges = false
        for (list, rule) in [
            (PolicyList.allowedConnections, "github.com:443"), (.blockedAddresses, "10.0.0.0/8"), (.blockedPorts, "8000-8100"),
            (.blockedURLPrefixes, "http://example.com/admin"),
        ] {
            try config.networkPolicy.add(rule, to: list)
        }

        let decoded = try VMConfig.decode(from: config.encoded())

        #expect(decoded.networkMode == .filtered)
        #expect(decoded.networkDenyAction == .drop)
        #expect(!decoded.networkResetsOnHostChange)
        #expect(decoded.networkPolicy == config.networkPolicy)
    }

    @Test func onlyNoneHasNoNetworkDevice() {
        #expect(NetworkMode.allCases.filter { !$0.hasNetworkDevice } == [.none])
        #expect(NetworkMode.filtered.label == "Filtered (user-mode)")
    }

    @Test func theStacksSettingsComeFromTheConfig() {
        var config = VMConfig.new(name: "f", guest: .linux)
        #expect(config.userNetConfig.denyAction == .reset)
        #expect(config.hostPathChangeAction == .terminate)

        config.networkDenyAction = .drop
        config.networkResetsOnHostChange = false

        #expect(config.userNetConfig.denyAction == .drop)
        #expect(config.userNetConfig.problem == nil)
        #expect(config.hostPathChangeAction == .keep)
    }
}

struct NetworkProfileTests {
    @Test(arguments: GuestOS.allCases)
    func profilesKeepTheirNetworkAndNoneUsesTheFilteredStack(guest: GuestOS) {
        let config = VMConfig.new(name: "x", guest: guest)
        #expect(config.applying(.standard).networkMode == .nat)
        #expect(config.applying(.contained).networkMode == .nat)
        #expect(config.applying(.isolated).networkMode == .none)
        #expect(config.applying(.hardened).networkMode == .none)
    }

    @Test func choosingAProfileLeavesFilteredModeAndKeepsTheRules() throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.networkMode = .filtered
        try config.networkPolicy.add("evil.com", to: .blockedDomains)

        let isolated = config.applying(.isolated)

        #expect(isolated.networkMode == .none)
        #expect(isolated.networkPolicy.rules(in: .blockedDomains) == ["evil.com"])
        #expect(config.detectedProfile == nil, "filtered networking matches no profile, so the machine reads as Custom")
    }

    @Test func filteredExposuresDescribeWhatIsEnforcedAndWhatIsNot() throws {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.networkMode = .filtered
        let blockList = config.exposures.map(\.text).filter { $0.hasPrefix("Network (filtered)") }
        #expect(blockList.count == 1)
        #expect(blockList[0].contains("private ranges are blocked"))
        #expect(config.exposures.contains { $0.text.contains("implemented by VMRunner itself") && $0.text.contains("not been validated") })
        #expect(!config.exposures.contains { $0.text.hasPrefix("Network: the guest can reach") })
        #expect(!config.exposures.contains { $0.text.contains("Domain rules are advisory") })

        try config.networkPolicy.add("*.example.com", to: .blockedDomains)
        #expect(config.exposures.contains { $0.text.contains("Domain rules are advisory") && $0.text.contains("DoH") })

        config.networkPolicy.blockPrivateRanges = false
        #expect(config.exposures.contains { $0.text.contains("private ranges are not blocked") })

        config.networkPolicy.mode = .allowListed
        #expect(config.exposures.contains { $0.level == .low && $0.text.contains("only destinations your allow-list names") })
        #expect(config.exposures.contains { $0.text.contains("look up only the names your allow-list names") })
    }
}

struct PolicyEditingTests {
    private static let valid: [PolicyList: String] = [
        .allowedDomains: "*.Example.com", .blockedDomains: "evil.COM.", .allowedAddresses: "203.0.113.0/24", .blockedAddresses: "10.1.2.3",
        .allowedPorts: "443", .blockedPorts: " 8000-8100 ", .allowedConnections: "github.com:443", .blockedConnections: "10.0.0.0/8:22,80",
        .allowedURLPrefixes: "http://example.com/downloads", .blockedURLPrefixes: "http://example.com/admin",
    ]
    private static let canonical: [PolicyList: String] = [
        .allowedDomains: "*.example.com", .blockedDomains: "evil.com", .allowedAddresses: "203.0.113.0/24", .blockedAddresses: "10.1.2.3",
        .allowedPorts: "443", .blockedPorts: "8000-8100", .allowedConnections: "github.com:443", .blockedConnections: "10.0.0.0/8:22,80",
        .allowedURLPrefixes: "http://example.com/downloads", .blockedURLPrefixes: "http://example.com/admin",
    ]

    @Test func everyListAcceptsItsKindOfRuleInCanonicalForm() throws {
        #expect(Set(Self.valid.keys) == Set(PolicyList.allCases))
        for list in PolicyList.allCases {
            var policy = NetworkPolicy()
            try policy.add(try #require(Self.valid[list]), to: list)
            #expect(policy.rules(in: list) == [try #require(Self.canonical[list])], "\(list)")
            for other in PolicyList.allCases where other != list {
                #expect(policy.rules(in: other).isEmpty, "\(list) leaked into \(other)")
            }
        }
    }

    @Test func aDuplicateIsNotAddedTwice() throws {
        var policy = NetworkPolicy()
        try policy.add("example.com", to: .blockedDomains)
        try policy.add("EXAMPLE.com", to: .blockedDomains)
        #expect(policy.rules(in: .blockedDomains) == ["example.com"])
    }

    @Test func removeTakesOutTheRuleAtThatPositionAndIgnoresBadIndexes() throws {
        var policy = NetworkPolicy()
        for port in ["22", "23", "25"] { try policy.add(port, to: .blockedPorts) }

        policy.remove(at: 1, from: .blockedPorts)
        policy.remove(at: 9, from: .blockedPorts)
        policy.remove(at: -1, from: .blockedPorts)

        #expect(policy.rules(in: .blockedPorts) == ["22", "25"])
    }

    @Test(arguments: [
        (PolicyList.blockedDomains, "not a domain!", NetworkPolicyError.invalidDomain("not a domain!")),
        (.blockedDomains, "127.0.0.1", .domainLooksLikeAddress("127.0.0.1")),
        (.blockedAddresses, "300.1.1.1", .invalidAddress("300.1.1.1")),
        (.blockedAddresses, "10.0.0.0/40", .invalidPrefixLength("10.0.0.0/40")),
        (.allowedPorts, "70000", .invalidPort("70000")),
        (.allowedPorts, "9000-8000", .invalidPort("9000-8000")),
        (.blockedConnections, "example.com:", .invalidConnection("example.com:")),
        (.blockedURLPrefixes, "https://example.com/x", .unsupportedScheme("https")),
        (.blockedURLPrefixes, "http://example.com/x?a=1", .unsupportedURLComponent("a query or fragment")),
        (.allowedDomains, "   ", .empty),
    ])
    func aBadRuleIsRefusedWithTheEnginesOwnErrorAndChangesNothing(list: PolicyList, text: String, expected: NetworkPolicyError) {
        var policy = NetworkPolicy()

        #expect(throws: expected) { try policy.add(text, to: list) }

        #expect(policy == NetworkPolicy())
        #expect(NetworkPolicy.problem(with: text, for: list) == expected)
    }

    @Test func aValidRuleHasNoProblem() {
        #expect(NetworkPolicy.problem(with: "example.com", for: .allowedDomains) == nil)
    }

    @Test func allowAndBlockListsPartitionAllLists() {
        #expect(Set(PolicyList.allowLists).isDisjoint(with: PolicyList.blockLists))
        #expect(Set(PolicyList.allowLists + PolicyList.blockLists) == Set(PolicyList.allCases))
        #expect(PolicyList.allowLists.allSatisfy { $0.rawValue.hasPrefix("allowed") })
        #expect(PolicyList.allCases.allSatisfy { !$0.example.isEmpty && !$0.tooltip.isEmpty && !$0.title.isEmpty })
    }

    @Test func domainRulesAreNoticedInDomainsAndInNamedConnectionsOnly() throws {
        var policy = NetworkPolicy()
        #expect(!policy.usesDomainRules)
        try policy.add("10.0.0.0/8:22", to: .blockedConnections)
        try policy.add("203.0.113.0/24", to: .blockedAddresses)
        #expect(!policy.usesDomainRules)
        try policy.add("example.com:443", to: .allowedConnections)
        #expect(policy.usesDomainRules)
    }
}

struct FlowLogTests {
    private func event(_ phase: FlowEvent.Phase, transport: FlowTransport = .tcp, name: String? = nil, port: UInt16 = 443) -> FlowEvent {
        FlowEvent(
            flowID: 1, transport: transport, phase: phase, remote: (IPv4.make(93, 184, 216, 34), port), name: name, time: 0)
    }

    @Test func anOpenedFlowIsAllowed() throws {
        let entry = try #require(FlowLogEntry(event: event(.opened, name: "example.com"), id: 7))
        #expect(entry.id == 7)
        #expect(entry.outcome == .allowed)
        #expect(entry.destination == "example.com (93.184.216.34:443)")
    }

    @Test func aDenialNamesTheRuleThatDecided() throws {
        let rule = try DomainRule("evil.com")
        let entry = try #require(FlowLogEntry(event: event(.denied(.policy(.blockedDomain(rule)))), id: 0))
        #expect(entry.outcome == .denied)
        #expect(entry.destination == "93.184.216.34:443")
        #expect(entry.detail.contains("evil.com"))
    }

    @Test func everyDenialExplainsItself() throws {
        let rule = try AddressRule("10.0.0.0/8")
        let ip = try address("10.1.1.1")
        let reasons: [NetworkPolicy.Reason] = [
            .malformedHost, .nonCanonicalAddress, .malformedURL, .unsupportedScheme("ftp"), .blockedPort(22),
            .blockedConnection(try ConnectionRule("a.com:22")), .portNotAllowListed(25), .urlNotAllowListed,
            .reservedRange(.privateNetwork, address: ip), .blockedAddress(rule, address: ip),
            .blockedDomain(try DomainRule("a.com")), .blockedURL(try URLRule("http://a.com/x")), .notAllowListed, .unresolved,
        ]
        for reason in reasons { #expect(!reason.explanation.isEmpty && reason.explanation.hasSuffix("."), "\(reason)") }
        #expect(NetworkPolicy.Reason.blockedPort(22).explanation == "Port 22 is blocked.")
        #expect(FlowDenial.gatewayService(port: 80).explanation.contains("80"))
        #expect(FlowDenial.flowLimit.explanation.contains("Too many"))
        #expect(FlowDenial.unroutable.explanation.contains("Multicast"))
    }

    @Test func dnsAnswersAreLoggedByNameAndTheirCodeIsExplained() throws {
        let resolved = try #require(
            FlowLogEntry(event: event(.answered(responseCode: 0), transport: .dns, name: "a.example.com", port: 53), id: 0))
        #expect(resolved.destination == "a.example.com")
        #expect(resolved.detail == "Name resolved")
        let missing = try #require(FlowLogEntry(event: event(.answered(responseCode: 3), transport: .dns, port: 53), id: 1))
        #expect(missing.detail == "No such name")
        #expect(missing.destination == "93.184.216.34:53")
    }

    @Test func anIcmpFlowHasNoPort() throws {
        let entry = try #require(FlowLogEntry(event: event(.opened, transport: .icmp, port: 0), id: 0))
        #expect(entry.destination == "93.184.216.34")
    }

    @Test func onlyAPolicyRevocationOfAClosedFlowIsWorthALine() throws {
        #expect(FlowLogEntry(event: event(.closed(.finished)), id: 0) == nil)
        #expect(FlowLogEntry(event: event(.closed(.idleTimeout)), id: 0) == nil)
        #expect(FlowLogEntry(event: event(.closed(.hostError(54))), id: 0) == nil)
        let revoked = try #require(FlowLogEntry(event: event(.closed(.policyRevoked(.blockedPort(443)))), id: 0))
        #expect(revoked.outcome == .denied)
        #expect(revoked.detail.contains("policy change"))
    }
}

struct VPNIndicatorTests {
    private let guestVPN = GuestVPNState.suspected(kind: .wireGuard, confidence: .high, since: 1, evidence: [])

    @Test func quietWhenNeitherSideHasAVPN() {
        let indicator = VPNIndicator(host: .inactive, guest: .none)
        #expect(indicator.level == .quiet)
        #expect(indicator.hostText == "Mac VPN: not detected")
        #expect(indicator.guestText == "Guest VPN: not detected")
        #expect(indicator.guestEvidence.isEmpty)
    }

    @Test func aHostVPNAloneIsOnlyANotice() {
        let indicator = VPNIndicator(host: .active, guest: .none)
        #expect(indicator.level == .hostVPN)
        #expect(indicator.hostText == "Mac VPN: active")
        #expect(indicator.symbol == "lock.shield")
    }

    @Test func aSuspectedGuestVPNOutranksTheHostsAndSaysHowSure() {
        let indicator = VPNIndicator(host: .active, guest: guestVPN)
        #expect(indicator.level == .guestVPN)
        #expect(indicator.guestText == "Guest VPN: WireGuard suspected (high confidence)")
        #expect(indicator.symbol == "exclamationmark.shield")
    }

    @Test func anUnknownHostStateIsReportedAsUnknownNotAsNoVPN() {
        #expect(VPNIndicator(host: .unknown, guest: .none).hostText == "Mac VPN: unknown")
        #expect(VPNIndicator(host: .unknown, guest: .none).level == .quiet)
    }
}
