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

    @Test func numbersInHelpComeFromTheSameConstantsAsTheControls() {
        let text = HelpTopic.diskSize.entry.paragraphs.joined(separator: " ")
        #expect(text.contains("\(EditorLimits.maxDiskGiB) GiB"))
        #expect(text.contains("\(EditorLimits.diskStepGiB) GiB"))
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
