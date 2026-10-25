import Foundation

/// The sections of a stopped machine's settings form, in the order they are shown.
enum EditorSection: CaseIterable, Identifiable {
    case general, container, security, compute, storage, installer, provisioning, display, input, audio, network, networkPolicy
    case identity, sharing, hostInfo, boot, devices, agentAccess, snapshots

    var id: Self { self }

    /// The sections that apply to `config`, in order. A container machine has a general section, its container settings and
    /// agent access (the control service starts and stops it); everything else is about a virtual machine's hardware.
    static func visible(for config: VMConfig) -> [Self] {
        allCases.filter { $0.isShown(for: config) }
    }

    private func isShown(for config: VMConfig) -> Bool {
        if config.workload == .container { return Self.containerSections.contains(self) }
        switch self {
        case .container: return false
        case .installer: return GuestEditorRows(config.guest).installer
        case .provisioning: return GuestEditorRows(config.guest).provisioning
        case .networkPolicy: return config.networkMode == .filtered
        case .boot: return GuestEditorRows(config.guest).firstBoot
        default: return true
        }
    }

    private static let containerSections: Set<Self> = [.general, .container, .agentAccess]
}
