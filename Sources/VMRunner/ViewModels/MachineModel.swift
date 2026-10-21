import AppKit
import Foundation
import Observation
import SwiftUI
import Virtualization

/// What the detail pane shows for one machine, and every action its toolbar and menus offer.
///
/// Views read these properties and call these methods; none of them touches the library, the controller, or the file
/// system directly.
@MainActor @Observable
final class MachineModel {
    /// The settings a running machine's display view needs, and nothing else.
    struct DisplaySettings: Equatable {
        var capturesSystemKeys: Bool
        var followsWindow: Bool
        var guest: GuestOS
        var scale: Double
    }

    enum Phase {
        case settingUp(SetupJob)
        case setupIncomplete
        case running(VZVirtualMachine, DisplaySettings)
        case editing
    }

    let id: UUID
    let editor: ConfigEditorModel
    var confirmingDelete = false

    private let library: VMLibrary

    init(id: UUID, library: VMLibrary) {
        self.id = id
        self.library = library
        editor = ConfigEditorModel(id: id, library: library)
    }

    // MARK: State

    private var controller: VMController { library.controller(for: id) }
    var config: VMConfig? { library.machine(id) }
    var configBinding: Binding<VMConfig>? { library.binding(for: id) }
    var title: String { config?.name ?? "" }
    var bundle: VMBundle { library.bundle(id) }

    var phase: Phase? {
        guard let config else { return nil }
        if let job = library.jobs[id] { return .settingUp(job) }
        if !config.isProvisioned { return .setupIncomplete }
        if let machine = controller.virtualMachine {
            let settings = DisplaySettings(
                capturesSystemKeys: config.capturesSystemKeys,
                followsWindow: config.automaticallyReconfiguresDisplay,
                guest: config.guest,
                scale: config.displayScale
            )
            return .running(machine, settings)
        }
        return .editing
    }

    var guestSymbol: String { config?.guest.symbol ?? "questionmark" }
    var showsControls: Bool { library.jobs[id] == nil && config?.isProvisioned == true }
    var isRunning: Bool { controller.isActive }
    var isPaused: Bool { controller.state == .paused }
    var deadline: Date? { controller.deadline }
    var canSuspend: Bool { controller.canSuspend }
    var suspendHelp: String {
        controller.canSuspend ? "Save state to disk and stop" : (controller.suspendUnavailableReason ?? "Suspend isn't available")
    }
    /// A file-system check, cheap enough for a toolbar but not something to call in a loop.
    var hasSavedState: Bool { bundle.hasSavedState }
    var startHelp: String { hasSavedState ? "Resume from suspended state" : "Start the virtual machine" }

    var errorMessage: String? {
        get { controller.errorMessage }
        set { controller.errorMessage = newValue }
    }

    // MARK: Layout

    /// The detail pane's size in points, used to size the guest display when the machine starts.
    func reportPaneSize(_ size: CGSize) { library.displayHint = size }

    // MARK: Actions

    func start() { library.startMachine(id) }
    func suspend() { library.suspendMachine(id) }
    func shutDown() { controller.requestStop() }
    func resumeSetup() { library.beginSetup(id) }

    func pause() {
        let controller = controller
        Task { await controller.pause() }
    }

    func resume() {
        let controller = controller
        Task { await controller.resume() }
    }

    func forceStop() {
        let controller = controller
        Task { await controller.forceStop() }
    }

    func retrySetup() {
        library.cancelJob(id)
        library.beginSetup(id)
    }

    func dismissSetup() { library.cancelJob(id) }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([bundle.url]) }
    func discardSavedState() { bundle.discardSavedState() }

    func duplicate() {
        do {
            try library.duplicate(id)
        } catch {
            library.alertMessage = "Couldn't duplicate “\(title)”: \(error.localizedDescription)"
        }
    }

    func delete() { library.delete(id) }
}
