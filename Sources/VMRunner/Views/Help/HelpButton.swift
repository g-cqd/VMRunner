import SwiftUI

/// A small "?" that explains one topic in a popover. Hovering shows the one-line summary.
struct HelpButton: View {
    let topic: HelpTopic

    @State private var showing = false

    init(_ topic: HelpTopic) { self.topic = topic }

    var body: some View {
        Button("Help: \(topic.title)", systemImage: "questionmark.circle") { showing.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(topic.summary)
            .popover(isPresented: $showing, arrowEdge: .trailing) { HelpPopover(topic: topic) }
    }
}

/// The popover body: the plain explanation first, the expert detail folded away.
struct HelpPopover: View {
    let topic: HelpTopic

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HelpEntryText(topic: topic, expandsAdvanced: false)
                Divider()
                Button("Open in Help", systemImage: "book") {
                    HelpNavigator.shared.show(topic)
                    openWindow(id: HelpWindow.id)
                }
                .buttonStyle(.link)
            }
            .padding()
        }
        .frame(width: 360)
        .frame(maxHeight: 420)
    }
}

/// Renders one topic: title, plain text, then the "For experienced users" section and related topics.
struct HelpEntryText: View {
    let topic: HelpTopic
    let expandsAdvanced: Bool

    @State private var showsAdvanced = false

    var body: some View {
        let entry = topic.entry
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title).font(.headline)
            ForEach(Array(entry.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                HelpParagraph(text: paragraph)
            }
            if !entry.advanced.isEmpty {
                DisclosureGroup("For experienced users", isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(entry.advanced.enumerated()), id: \.offset) { _, paragraph in
                            HelpParagraph(text: paragraph)
                        }
                    }
                    .padding(.top, 4)
                }
                .onAppear { showsAdvanced = expandsAdvanced }
            }
        }
        .textSelection(.enabled)
    }
}

private struct HelpParagraph: View {
    let text: String

    var body: some View {
        let isBullet = text.hasPrefix("• ")
        let content = isBullet ? String(text.dropFirst(2)) : text
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isBullet { Text("•") }
            Text(markdown(content)).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    /// Inline Markdown (bold, italics, code); falls back to the raw text if it can't be parsed.
    private func markdown(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}

extension View {
    /// Adds a tooltip with the topic's summary and a trailing "?" button that opens its explanation.
    func settingHelp(_ topic: HelpTopic) -> some View {
        HStack(alignment: .firstTextBaseline) {
            self.help(topic.summary)
            HelpButton(topic)
        }
    }
}

/// A section header with a "?" for the whole section.
struct HelpHeader: View {
    let title: String
    let topic: HelpTopic

    init(_ title: String, topic: HelpTopic) {
        self.title = title
        self.topic = topic
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            HelpButton(topic)
        }
    }
}
