import SwiftUI
import Virtualization

/// CPU cores, memory, and nested virtualization.
struct ComputeSection: View {
    @Binding var cpuCount: Int
    @Binding var memoryMiB: Int
    @Binding var nestedVirtualization: Bool
    let guest: GuestOS

    private var nestedSupported: Bool { VZGenericPlatformConfiguration.isNestedVirtualizationSupported }

    var body: some View {
        Section {
            CoreAndMemorySteppers(cpuCount: $cpuCount, memoryMiB: $memoryMiB, memoryStepMiB: EditorLimits.memoryStepMiB)
            if guest == .linux { nestedRows }
        } header: {
            HelpHeader("Compute", topic: .cpuCores)
        }
    }

    @ViewBuilder
    private var nestedRows: some View {
        Toggle("Nested virtualization", isOn: $nestedVirtualization)
            .disabled(!nestedSupported)
            .settingHelp(.nestedVirtualization)
        Text(
            nestedSupported
                ? "Exposes /dev/kvm to the guest (for containers, Podman, or QEMU inside the VM)."
                : "Needs an M3 or newer chip and macOS 15+."
        )
        .font(.caption).foregroundStyle(.secondary)
    }
}
