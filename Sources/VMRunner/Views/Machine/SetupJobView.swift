import SwiftUI

/// Progress (or the failure) of downloading and installing a machine.
struct SetupJobView: View {
    let job: SetupJob
    let symbol: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            if let error = job.error {
                failure(error)
            } else {
                progress
            }
            HelpButton(.setup)
        }
        .frame(maxWidth: 420)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Label("Setup failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).textSelection(.enabled).multilineTextAlignment(.center)
            HStack {
                Button("Retry", action: retry)
                Button("Dismiss", action: dismiss)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 12) {
            Text(job.title).font(.headline)
            if let notice = job.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            }
            if let fraction = job.fraction {
                ProgressView(value: fraction) {
                    EmptyView()
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(1)))
                }
            } else {
                ProgressView()
            }
            Button("Cancel") { job.cancel() }
        }
    }
}
