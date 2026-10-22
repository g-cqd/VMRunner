import Foundation
import Virtualization

/// The part of Virtualization.framework the controller drives, and nothing more. A test supplies its own to run the
/// controller's transitions without a virtual machine; `VZGuestMachine` is the real one.
@MainActor
protocol GuestMachine: AnyObject {
    /// The framework's machine, for the view that displays it; `nil` for a test double.
    var virtualMachine: VZVirtualMachine? { get }
    /// Whether the framework allows a stop now. It does not while a start, a pause or a resume is in flight.
    var canStop: Bool { get }
    /// Called when the guest powers off by itself, and when the machine stops because of an error. The controller sets them
    /// once, right after it receives the machine, and clears them when it lets the machine go. The controller's own state
    /// never copies the framework's: it follows the outcome of each call and these two reports.
    var onGuestStopped: (@MainActor () -> Void)? { get set }
    var onStoppedWithError: (@MainActor (_ message: String) -> Void)? { get set }
    /// The kill switch of this run, when the machine has one, for the toolbar.
    var networkCutoff: NetworkCutoff? { get }

    func start() async throws
    func restoreState(from url: URL) async throws
    func saveState(to url: URL) async throws
    func pause() async throws
    func resume() async throws
    /// Presses the guest's power button.
    func requestStop() throws
    /// Pulls the plug.
    func stop() async throws
}

/// Whether a configuration's memory can be saved, and if not, what to tell the user.
enum SuspendSupport: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

/// A machine ready to start: its framework object, the stack its network device talks to (not started), and whether a
/// suspend can work.
struct PreparedMachine {
    let machine: any GuestMachine
    let network: NetworkActivity?
    let suspend: SuspendSupport
}

/// Builds the framework objects for one attempt to start. Each attempt gets its own machine and network stack: a
/// configuration that failed to restore can't be reused, and neither can its stack.
@MainActor
protocol MachineFactory {
    func prepare(
        _ config: VMConfig, bundle: VMBundle, display: (width: Int, height: Int), suspendAllowed: Bool
    ) async throws -> PreparedMachine
}
