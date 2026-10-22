import Virtualization

/// With `--display-diagnostics`: logs when the framework starts and finishes reconfiguring a machine's display, whether the
/// view asked for it (macOS guests) or `DisplayFollower` did (Linux guests).
final class DisplayTrace: NSObject, VZGraphicsDisplayObserver {
    private weak var display: VZGraphicsDisplay?

    init?(machine: VZVirtualMachine) {
        guard DisplayDiagnostics.isEnabled, let display = machine.graphicsDevices.first?.displays.first else { return nil }
        self.display = display
        super.init()
        display.addObserver(self)
    }

    deinit { display?.removeObserver(self) }

    func displayDidBeginReconfiguration(_ display: VZGraphicsDisplay) {
        DisplayDiagnostics.note("framework began reconfiguring the display; it is \(DisplayDiagnostics.text(display.sizeInPixels)) px")
    }

    func displayDidEndReconfiguration(_ display: VZGraphicsDisplay) {
        DisplayDiagnostics.note("framework finished reconfiguring the display; it is \(DisplayDiagnostics.text(display.sizeInPixels)) px")
    }
}
