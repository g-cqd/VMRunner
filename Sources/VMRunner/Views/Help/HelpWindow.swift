import SwiftUI

/// Identifier of the Help window scene.
enum HelpWindow {
    static let id = "help"
}

/// The searchable Help window: topics grouped by area on the left, the explanation on the right.
struct HelpWindowView: View {
    @Bindable var navigator: HelpNavigator

    var body: some View {
        NavigationSplitView {
            List(selection: $navigator.selection) {
                ForEach(navigator.results, id: \.area) { group in
                    Section(group.area.rawValue) {
                        ForEach(group.topics) { topic in
                            Text(topic.title).tag(topic)
                        }
                    }
                }
            }
            .searchable(text: $navigator.query, placement: .sidebar, prompt: "Search help")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .overlay {
                if navigator.results.isEmpty {
                    ContentUnavailableView.search(text: navigator.query)
                }
            }
        } detail: {
            if let topic = navigator.selection {
                HelpDetail(topic: topic, navigator: navigator)
            } else {
                ContentUnavailableView("Choose a topic", systemImage: "book")
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .navigationTitle("VMRunner Help")
    }
}

private struct HelpDetail: View {
    let topic: HelpTopic
    let navigator: HelpNavigator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HelpEntryText(topic: topic, expandsAdvanced: true)
                if !topic.entry.related.isEmpty {
                    Divider()
                    Text("Related").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(topic.entry.related) { related in
                        Button(related.title) { navigator.show(related) }
                            .buttonStyle(.link)
                            .help(related.summary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
