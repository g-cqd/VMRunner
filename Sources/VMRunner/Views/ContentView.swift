import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(VMLibrary.self) private var library
    @AppStorage("hidesToolbarInFullScreen") private var hidesToolbarInFullScreen = true
    @State private var window: NSWindow?
    @State private var isFullScreen = false

    /// In full screen the running guest gets the whole screen: no toolbar, no sidebar.
    private var immersive: Bool {
        isFullScreen && hidesToolbarInFullScreen && library.selectedController?.isActive == true
    }

    var body: some View {
        @Bindable var library = library
        // A collapsed split view keeps its column width and the toolbar's safe area, leaving a gap around the
        // guest, so full screen swaps it for the bare machine view.
        Group {
            if immersive, let id = library.selection {
                MachineView(model: library.model(for: id))
                    .id(id)
                    .ignoresSafeArea()
                    .toolbarVisibility(.hidden, for: .windowToolbar)
            } else {
                splitView
            }
        }
        .background(WindowReader(window: $window))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if note.object as? NSWindow === window { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if note.object as? NSWindow === window { isFullScreen = false }
        }
        .sheet(isPresented: $library.showingNewMachine) { NewMachineSheet() }
        .alert(
            "VMRunner",
            isPresented: Binding(get: { library.alertMessage != nil }, set: { if !$0 { library.alertMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(library.alertMessage ?? "")
        }
    }

    private var splitView: some View {
        @Bindable var library = library
        return NavigationSplitView {
            List(library.machines, selection: $library.selection) { machine in
                MachineRow(config: machine)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button("New Machine", systemImage: "plus") { library.showingNewMachine = true }
                }
            }
            .overlay {
                if library.machines.isEmpty {
                    ContentUnavailableView {
                        Label("No Machines", systemImage: "desktopcomputer")
                    } description: {
                        Text("Create a macOS or Linux virtual machine.")
                    } actions: {
                        Button("New Machine…") { library.showingNewMachine = true }
                    }
                }
            }
        } detail: {
            if let id = library.selection, library.machine(id) != nil {
                MachineView(model: library.model(for: id)).id(id)
            } else {
                ContentUnavailableView("Select a Machine", systemImage: "sidebar.left")
            }
        }
        .alert(
            "Approve host access?",
            isPresented: Binding(get: { library.pendingApproval != nil }, set: { if !$0 { library.pendingApproval = nil } }),
            presenting: library.pendingApproval
        ) { _ in
            Button("Approve and Start") { library.approvePendingAndStart() }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }
}

/// Reports the window that hosts a SwiftUI hierarchy.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onWindowChange = { window = $0 }
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {}
}

private final class WindowObservingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit declares `window` unowned(unsafe); it is alive for the duration of this callback, and the
        // reference is stored only as a strong `NSWindow?` by the caller.
        onWindowChange?(unsafe window)
    }
}

private struct MachineRow: View {
    @Environment(VMLibrary.self) private var library
    let config: VMConfig

    var body: some View {
        let controller = library.controller(for: config.id)
        HStack {
            Image(systemName: config.guest.symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                Text("\(config.guest.label) · \(config.cpuCount) CPU · \(config.memoryMiB / 1024) GiB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if library.jobs[config.id] != nil {
                ProgressView().controlSize(.small)
            } else if let color = statusColor(controller.state) {
                Circle().fill(color).frame(width: 8, height: 8)
            }
        }
        .tag(config.id)
    }

    private func statusColor(_ state: MachineState) -> Color? {
        switch state.indicator {
        case .running: .green
        case .paused: .orange
        case .busy: .yellow
        case .none: nil
        }
    }
}
