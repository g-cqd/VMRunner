import SwiftUI

/// What a container machine shows in place of a screen: the container's output, the time each runner phase took, how the run
/// ended, and the runner's own diagnostics under a disclosure. The text is bounded and already filtered by `ContainerLog`.
struct ContainerLogView: View {
    let log: ContainerLog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(log.output.markedText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .defaultScrollAnchor(.bottom)
            .accessibilityLabel("Container output")
            Divider()
            footer
        }
        .background(.background)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = Self.phaseSummary(log.phases) {
                Text(summary).foregroundStyle(.secondary)
            }
            if let status = Self.statusLine(for: log) {
                Text(status)
            }
            ForEach(Array(log.errors.enumerated()), id: \.offset) { _, message in
                Text(message).foregroundStyle(.red)
            }
            if !log.diagnostics.text.isEmpty {
                DisclosureGroup("Runner diagnostics") {
                    ScrollView {
                        Text(log.diagnostics.markedText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    /// `pull 1.2 s · boot 0.9 s`, or `nil` before the first phase ends.
    static func phaseSummary(_ phases: [ContainerLog.Phase]) -> String? {
        guard !phases.isEmpty else { return nil }
        return phases.map { "\($0.name) \($0.seconds.formatted(.number.precision(.fractionLength(1)))) s" }.joined(separator: " · ")
    }

    /// How the run ended, once it did.
    static func statusLine(for log: ContainerLog) -> String? {
        if let status = log.containerStatus { return "The container exited with status \(status)." }
        guard let status = log.finishedStatus else { return nil }
        return "The container runner finished with status \(status)."
    }
}
