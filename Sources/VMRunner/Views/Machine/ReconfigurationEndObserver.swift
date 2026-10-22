import Virtualization

extension VZGraphicsDisplay {
    /// `ResizableDisplay`: the framework's own report that a requested size reached the guest and frames arrived at it.
    func observeReconfigurationEnd(_ handler: @escaping @MainActor () -> Void) -> AnyObject {
        ReconfigurationEndObserver(display: self, handler: handler)
    }
}

/// Adopts `VZGraphicsDisplayObserver` for `DisplayFollower`, and stops observing when it goes away.
///
/// The framework calls the observer on the machine's queue, and not at all when the guest does not use a requested size, so
/// the end of a reconfiguration is the sign that the guest responded.
final class ReconfigurationEndObserver: NSObject, VZGraphicsDisplayObserver {
    private weak var display: VZGraphicsDisplay?
    private let handler: @MainActor () -> Void

    init(display: VZGraphicsDisplay, handler: @escaping @MainActor () -> Void) {
        self.display = display
        self.handler = handler
        super.init()
        display.addObserver(self)
    }

    deinit { display?.removeObserver(self) }

    func displayDidEndReconfiguration(_ display: VZGraphicsDisplay) {
        let handler = handler
        Task { @MainActor in handler() }
    }
}
