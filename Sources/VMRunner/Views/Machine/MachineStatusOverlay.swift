import SwiftUI

/// What the display shows over a machine that is not simply running, so a state is never something the user has to guess.
///
/// A paused machine is dimmed, named, and offers the way out; a machine in the middle of a step says which step. Both read
/// the machine's one state.
struct MachineStatusOverlay: View {
    let model: MachineModel

    var body: some View {
        let state = model.state
        switch state {
        case .paused:
            PausedLayer(resume: model.resume)
        case .stopped, .running:
            EmptyView()
        default:
            if let status = state.statusText {
                StepBadge(status: status, offersForceStop: state == .shuttingDown || state == .stopping, forceStop: model.forceStop)
            }
        }
    }
}

/// A dimmed display with the word Paused and the Resume button. The guest is frozen, so the layer takes the input.
private struct PausedLayer: View {
    let resume: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 12) {
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.title)
                Button("Resume", systemImage: "play.fill", action: resume)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Paused")
    }
}

/// A step in progress, at the top of the display. Only the badge takes clicks; the guest keeps the rest.
private struct StepBadge: View {
    let status: String
    let offersForceStop: Bool
    let forceStop: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status)
                if offersForceStop {
                    Button("Force Stop", action: forceStop)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
            if offersForceStop {
                Text("If the guest doesn't respond, Force Stop pulls the plug.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
