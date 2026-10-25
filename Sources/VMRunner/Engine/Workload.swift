import Foundation

/// What a running workload can do, so the controller and the interface offer a control only when the workload has it.
struct WorkloadCapabilities: OptionSet, Sendable {
    let rawValue: Int

    /// A framebuffer to show; without it the workload shows a log.
    static let display = Self(rawValue: 1 << 0)
    /// Pause and resume.
    static let pause = Self(rawValue: 1 << 1)
    /// Save the state to disk and restore it at the next start.
    static let suspend = Self(rawValue: 1 << 2)
    /// A filtered network stack whose flows the interface lists.
    static let networkActivity = Self(rawValue: 1 << 3)

    /// Everything a virtual machine does.
    static let virtualMachine: Self = [.display, .pause, .suspend, .networkActivity]
}

/// Why a workload refuses a call its capabilities do not include.
struct WorkloadUnsupportedError: LocalizedError, Equatable {
    let operation: String
    var errorDescription: String? { "This machine does not support \(operation)." }
}

/// What the controller drives, whatever the machine runs: a virtual machine (`GuestMachine`) or a container. A test supplies
/// its own to run the controller's transitions without starting anything.
@MainActor
protocol Workload: AnyObject {
    /// What this workload can do. The controller and the interface read it; a call outside it throws.
    var capabilities: WorkloadCapabilities { get }
    /// Whether a stop is allowed now. A virtual machine does not allow one while a start, a pause or a resume is in flight.
    var canStop: Bool { get }
    /// Called when the guest powers off by itself, and when the machine stops because of an error. The controller sets them
    /// once, right after it receives the machine, and clears them when it lets the machine go. The controller's own state
    /// never copies the workload's: it follows the outcome of each call and these two reports.
    var onGuestStopped: (@MainActor () -> Void)? { get set }
    var onStoppedWithError: (@MainActor (_ message: String) -> Void)? { get set }
    /// The kill switch of this run, when the workload has one, for the toolbar.
    var networkCutoff: NetworkCutoff? { get }

    func start() async throws
    /// Presses the guest's power button.
    func requestStop() throws
    /// Pulls the plug.
    func stop() async throws

    /// The next four are for the `suspend` and `pause` capabilities; a workload without them keeps the defaults, which throw.
    func restoreState(from url: URL) async throws
    func saveState(to url: URL) async throws
    func pause() async throws
    func resume() async throws
}

extension Workload {
    func restoreState(from url: URL) async throws { throw WorkloadUnsupportedError(operation: "restoring saved state") }
    func saveState(to url: URL) async throws { throw WorkloadUnsupportedError(operation: "suspending") }
    func pause() async throws { throw WorkloadUnsupportedError(operation: "pausing") }
    func resume() async throws { throw WorkloadUnsupportedError(operation: "resuming") }
}
