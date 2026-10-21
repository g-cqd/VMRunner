import Observation

/// Which help topic the Help window should show. Popovers set it and then open the window.
@MainActor @Observable
final class HelpNavigator {
    static let shared = HelpNavigator()

    var selection: HelpTopic? = .overview
    var query = ""

    /// Topics to list for the current search, grouped by area in declaration order.
    var results: [(area: HelpArea, topics: [HelpTopic])] {
        let matching = Set(HelpCatalog.search(query))
        return HelpArea.allCases.compactMap { area in
            let topics = HelpTopic.allCases.filter { $0.area == area && matching.contains($0) }
            return topics.isEmpty ? nil : (area, topics)
        }
    }

    func show(_ topic: HelpTopic) {
        query = ""
        selection = topic
    }
}
