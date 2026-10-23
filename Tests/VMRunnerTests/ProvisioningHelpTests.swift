import Testing

@testable import VMRunner

/// The help topic of provisioning says it is experimental, what the guest can read and what turns it off.
struct ProvisioningHelpTests {
    @Test
    func theTopicSaysItIsExperimentalAndWhatTheGuestCanRead() {
        let entry = HelpTopic.provisioning.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        #expect(entry.title == "Provisioning (experimental)")
        #expect(entry.summary.hasSuffix("Experimental."))
        #expect(text.contains("Experimental: the seed has been tried once, on one Debian 13 cloud image"))
        #expect(text.contains("the scripts run as root"))
        #expect(text.contains("Isolated and Hardened"))
        #expect(text.contains("`AllowProvisioning`"))
        #expect(entry.related.contains(.exposureSummary))
    }
}
