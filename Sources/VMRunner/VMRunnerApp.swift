import AppKit
import SwiftUI
import Virtualization
import os

@main
struct VMRunnerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let library = VMLibrary.shared
    @AppStorage("hidesToolbarInFullScreen") private var hidesToolbarInFullScreen = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    library.load()
                    await autoStartFromArguments()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Machine…") { library.showingNewMachine = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Toggle("Hide Toolbar in Full Screen", isOn: $hidesToolbarInFullScreen)
            }
            MachineCommands(library: library)
        }

        Window("VMRunner Help", id: HelpWindow.id) {
            HelpWindowView(navigator: HelpNavigator.shared)
        }
        .commands { CommandGroup(replacing: .help) { HelpMenuButton() } }

        Settings {
            SettingsView()
        }
    }

    /// `VMRunner --start <name or uuid>` boots a machine at launch, handy for scripting.
    private func autoStartFromArguments() async {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--start"), arguments.indices.contains(flag + 1) else { return }
        let key = arguments[flag + 1]
        let id: UUID
        switch MachineLookup.resolve(key, in: library.machines) {
        case .found(let found):
            id = found
        case .notFound:
            Log.machine.error("--start: no machine is named or numbered “\(key, privacy: .private)”")
            return
        case .ambiguous(let count):
            Log.machine.error("--start: \(count) machines are named “\(key, privacy: .private)”; use the machine's id instead")
            return
        }
        library.selection = id
        // Give the window a moment to lay out so the guest display can match its size.
        await poll(every: .milliseconds(100), attempts: 20, clock: ContinuousClock()) { library.displayHint != nil }
        library.startMachine(id, interactive: false)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            VMLibrary.shared.flushPendingWrites()
            VMLibrary.shared.discardAllEphemeral()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { VMLibrary.shared.runningCount }
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(running) virtual machine\(running == 1 ? " is" : "s are") still running."
        alert.informativeText =
            "Quitting force-stops them, like pulling the power cord. Suspend or shut them down first to avoid data loss."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct MachineCommands: Commands {
    let library: VMLibrary

    var body: some Commands {
        CommandMenu("Machine") {
            let id = library.selection
            let controller = library.selectedController
            let active = controller?.isActive ?? false

            Button("Start") { if let id { library.startMachine(id) } }
                .keyboardShortcut("r")
                .disabled(id == nil || active || library.machine(id ?? UUID())?.isProvisioned != true)
            if controller?.state == .paused {
                Button("Resume") { Task { await controller?.resume() } }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            } else {
                Button("Pause") { Task { await controller?.pause() } }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(!active)
            }
            Button("Suspend") { if let id { library.suspendMachine(id) } }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!active || controller?.canSuspend != true)
            Divider()
            Button("Shut Down") { controller?.requestStop() }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(!active)
            Button("Force Stop") { Task { await controller?.forceStop() } }
                .keyboardShortcut(".", modifiers: [.command, .option, .shift])
                .disabled(!active)
        }
    }
}

/// "VMRunner Help" in the Help menu.
private struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("VMRunner Help") { openWindow(id: HelpWindow.id) }
            .keyboardShortcut("?", modifiers: .command)
    }
}
