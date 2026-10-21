import Foundation
import Testing

@testable import VMRunner

struct HelpCatalogTests {
    @Test func everyTopicHasAnEntry() {
        let missing = Set(HelpTopic.allCases).subtracting(Set(HelpCatalog.entries.keys))
        #expect(missing.isEmpty, "topics without help text: \(missing.map(\.rawValue).sorted())")
    }

    @Test func noEntryIsOrphanedFromTheTopicList() {
        #expect(Set(HelpCatalog.entries.keys).isSubset(of: Set(HelpTopic.allCases)))
    }

    @Test(arguments: HelpTopic.allCases)
    func entriesAreComplete(topic: HelpTopic) {
        let entry = topic.entry
        #expect(!entry.title.isEmpty)
        #expect(!entry.paragraphs.isEmpty, "\(topic.rawValue) has no body")
        #expect(entry.paragraphs.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(entry.advanced.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    @Test(arguments: HelpTopic.allCases)
    func summariesFitATooltip(topic: HelpTopic) {
        let summary = topic.summary
        #expect(!summary.isEmpty)
        #expect(summary.count <= 110, "\(topic.rawValue) summary is \(summary.count) characters: \(summary)")
        #expect(summary.hasSuffix("."), "\(topic.rawValue) summary should be a sentence")
    }

    @Test func titlesAreUnique() {
        let titles = HelpTopic.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test(arguments: HelpTopic.allCases)
    func relatedTopicsAreRealAndNotSelfReferential(topic: HelpTopic) {
        #expect(!topic.entry.related.contains(topic))
        #expect(topic.entry.related.allSatisfy { Set(HelpCatalog.entries.keys).contains($0) })
    }

    @Test func eachAreaHasAtLeastOneTopic() {
        for area in HelpArea.allCases {
            #expect(HelpTopic.allCases.contains { $0.area == area }, "\(area.rawValue) is empty")
        }
    }

    @Test func searchMatchesTitleBodyAndAdvancedText() {
        #expect(HelpCatalog.search("rosetta").contains(.rosetta))
        #expect(HelpCatalog.search("copy-on-write").contains(.snapshots))
        #expect(HelpCatalog.search("SPICE").contains(.clipboard))
        #expect(HelpCatalog.search("   ").count == HelpTopic.allCases.count)
        #expect(HelpCatalog.search("zzzzqqqq").isEmpty)
    }

    @Test func searchRequiresEveryWord() {
        #expect(HelpCatalog.search("disk flush").contains(.diskSync))
        #expect(!HelpCatalog.search("rosetta snapshots").contains(.rosetta))
    }

    @Test func theSearchIndexCoversEveryTopicInOrder() {
        #expect(HelpCatalog.searchIndex.map(\.topic) == HelpTopic.allCases)
        for (topic, haystack) in HelpCatalog.searchIndex {
            #expect(haystack == haystack.lowercased())
            #expect(haystack.contains(topic.title.lowercased()), "\(topic.rawValue) title is not searchable")
        }
    }

    /// The query-time scan that the index replaced: lowercase and join each entry's text on every call.
    private func searchWithoutIndex(_ query: String) -> [HelpTopic] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return HelpTopic.allCases }
        return HelpTopic.allCases.filter { topic in
            let entry = topic.entry
            let haystack = ([entry.title, entry.summary] + entry.paragraphs + entry.advanced).joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    @Test(arguments: ["rosetta", "SPICE", "disk flush", "  Network   POLICY ", "copy-on-write", "memory", "a", "", "zzzzqqqq"])
    func searchResultsAreUnchangedByTheIndex(query: String) {
        #expect(HelpCatalog.search(query) == searchWithoutIndex(query))
    }

    @Test func theNetworkPolicyHelpStaysHonestAboutItsLimits() {
        let limits = (HelpTopic.policyLimits.entry.paragraphs + HelpTopic.policyLimits.entry.advanced).joined(separator: " ")
        let phrases = ["advisory", "DNS over HTTPS", "DNS over QUIC", "No IPv6", "IPsec and PPTP", "port 53", "not been validated"]
        // What the built-in DNS refuses and removes, so the help does not promise a plain resolver.
        for phrase in phrases + ["not implemented", ".local", "search domains", "removed from answers"] {
            #expect(limits.contains(phrase) || limits.contains(phrase.lowercased()), "missing: \(phrase)")
        }
        let vpn = HelpTopic.guestVpn.entry.paragraphs.joined(separator: " ")
        #expect(vpn.contains("Both are guesses"))
        #expect(HelpTopic.networkPolicy.entry.paragraphs.joined(separator: " ").contains("always wins"))
        let policy = HelpTopic.networkPolicy.entry.paragraphs.joined(separator: " ")
        #expect(policy.contains("Your Mac's own addresses are always blocked") && policy.contains("169.254.169.254"))
        #expect(HelpTopic.networkPolicy.entry.related.contains(.policyLimits))
    }

    @Test func numbersInHelpComeFromTheSameConstantsAsTheControls() {
        let text = HelpTopic.diskSize.entry.paragraphs.joined(separator: " ")
        #expect(text.contains("\(EditorLimits.maxDiskGiB) GiB"))
        #expect(text.contains("\(EditorLimits.diskStepGiB) GiB"))
        let rules = HelpTopic.policyRules.entry.paragraphs.joined(separator: " ")
        #expect(rules.contains("\(EditorLimits.maxRulesPerList) rules"))
    }
}

@MainActor
struct HelpNavigatorTests {
    @Test func showingATopicSelectsItAndClearsTheSearch() {
        let navigator = HelpNavigator()
        navigator.query = "disk"
        navigator.show(.snapshots)
        #expect(navigator.selection == .snapshots)
        #expect(navigator.query.isEmpty)
    }

    @Test func resultsAreGroupedByAreaInOrder() {
        let navigator = HelpNavigator()
        let areas = navigator.results.map(\.area)
        #expect(areas == HelpArea.allCases.filter { area in HelpTopic.allCases.contains { $0.area == area } })
    }

    @Test func searchNarrowsTheResults() {
        let navigator = HelpNavigator()
        navigator.query = "rosetta"
        #expect(navigator.results.flatMap(\.topics).contains(.rosetta))
        #expect(navigator.results.flatMap(\.topics).count < HelpTopic.allCases.count)
    }
}
