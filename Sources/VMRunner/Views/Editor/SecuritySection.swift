import SwiftUI

/// Security profile, isolation switches, and the summary of what the guest can reach on the host.
struct SecuritySection: View {
    @Binding var config: VMConfig
    let bundle: VMBundle

    private var rows: GuestEditorRows { GuestEditorRows(config.guest) }

    private var profileBinding: Binding<SecurityProfile?> {
        Binding(
            get: { config.detectedProfile },
            set: { profile in
                guard let profile else { return }
                config = config.applying(profile)
                bundle.discardSavedState()
            }
        )
    }

    var body: some View {
        Section {
            Picker("Profile", selection: profileBinding) {
                ForEach(SecurityProfile.allCases) { Text($0.label).tag(Optional($0)) }
                if config.detectedProfile == nil { Text("Custom").tag(SecurityProfile?.none) }
            }
            .settingHelp(.securityProfiles)
            Text(config.detectedProfile?.summary ?? "Custom: individual settings differ from every profile. Pick one to reset them.")
                .font(.caption).foregroundStyle(.secondary)
            if let note = WindowsRequirements.profileNote(for: config) {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }

            Toggle("Disposable (discard all changes on stop)", isOn: $config.ephemeral)
                .managedLock(.requireDisposableMachines)
                .settingHelp(.disposable)
            if rows.allowSuspend {
                Toggle("Allow suspend (writes memory to disk)", isOn: $config.allowsSuspend)
                    .disabled(config.ephemeral)
                    .managedLock(.allowSuspend)
                    .settingHelp(.suspendResume)
            }
            ValueStepper(
                title: "Runtime limit", value: $config.maxRuntimeMinutes, range: EditorLimits.runtimeMinutes,
                step: EditorLimits.runtimeStepMinutes,
                text: config.maxRuntimeMinutes == 0 ? "Off" : "\(config.maxRuntimeMinutes) min"
            )
            .managedLock(.maxRuntimeMinutes)
            .settingHelp(.runtimeLimit)
            if rows.secureBoot { secureBootRows }
            exposures
        } header: {
            HelpHeader("Security", topic: .securityProfiles)
        }
    }

    @ViewBuilder
    private var secureBootRows: some View {
        Toggle("Secure Boot", isOn: $config.secureBoot)
            .disabled(!config.secureBootIsEditable)
            .settingHelp(.secureBoot)
        Text(config.secureBootNote)
            .font(.caption).foregroundStyle(.secondary)
    }

    private var exposures: some View {
        DisclosureGroup {
            ForEach(config.exposures.sorted { $0.level > $1.level }) { exposure in
                Label {
                    Text(exposure.text)
                } icon: {
                    Image(systemName: exposure.level == .none ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(exposure.level.color)
                }
                .font(.callout)
            }
            Text("These settings narrow the channels between guest and host. They don't make an untrusted guest safe on their own.")
                .font(.caption).foregroundStyle(.secondary)
        } label: {
            HStack {
                Text("What this machine can reach on the host")
                HelpButton(.exposureSummary)
            }
        }
    }
}

extension Exposure.Level {
    fileprivate var color: Color {
        switch self {
        case .none: .green
        case .low: .yellow
        case .medium: .orange
        case .high: .red
        }
    }
}
