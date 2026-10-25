import Foundation
import Virtualization

/// The part of Virtualization.framework the controller drives, and nothing more: a `Workload` that is a virtual machine. A
/// test supplies its own to run the controller's transitions without a virtual machine; `VZGuestMachine` is the real one.
@MainActor
protocol GuestMachine: Workload {
    /// The framework's machine, for the view that displays it; `nil` for a test double.
    var virtualMachine: VZVirtualMachine? { get }
}

/// Whether a configuration's memory can be saved, and if not, what to tell the user.
enum SuspendSupport: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

/// A machine ready to start: its workload, the stack its network device talks to (not started), and whether a suspend can
/// work.
struct PreparedMachine {
    let machine: any Workload
    let network: NetworkActivity?
    let suspend: SuspendSupport
}

/// Builds the objects for one attempt to start. Each attempt gets its own machine and network stack: a configuration that
/// failed to restore can't be reused, and neither can its stack.
@MainActor
protocol MachineFactory {
    func prepare(
        _ config: VMConfig, bundle: VMBundle, display: (width: Int, height: Int), suspendAllowed: Bool
    ) async throws -> PreparedMachine
}
