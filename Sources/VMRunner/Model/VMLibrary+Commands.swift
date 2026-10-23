import Foundation

/// What came of a request to start, suspend or stop a machine, for a caller that waits for it (the control service, and the
/// menus through the same path).
enum MachineCommandResult: Equatable, Sendable {
    /// The request ran; the machine is now in this state.
    case done(MachineState)
    /// The request was not made, for this reason, written for the person or agent that asked.
    case refused(String)
    /// The request was made and failed, with the controller's message.
    case failed(String)
}

extension VMLibrary {
    /// Starts a machine without asking anything, and returns once the start has finished: the machine runs, or the start
    /// failed. Host paths the user has not approved refuse the start, as for a launch argument: nobody is there to ask.
    func startAndWait(_ id: UUID) async -> MachineCommandResult {
        guard let config = machine(id) else { return .refused("There is no such machine.") }
        guard config.isProvisioned else { return .refused("“\(config.name)” is not set up yet.") }
        guard jobs[id] == nil else { return .refused("“\(config.name)” is being set up.") }
        let controller = controller(for: id)
        guard controller.state.canStart else { return .refused("“\(config.name)” is already \(controller.state.activity).") }
        guard unapprovedHostPaths(for: id).isEmpty else {
            return .refused("“\(config.name)” uses host paths you have not approved in VMRunner. Start it once from the app.")
        }
        await controller.start(config, bundle: bundle(id), library: self, windowSize: displayHint)
        return Self.result(of: controller) { $0 == .running }
    }

    /// Suspends a machine and returns once its memory is saved and it has stopped, or the suspend was refused or failed.
    func suspendAndWait(_ id: UUID) async -> MachineCommandResult {
        guard let config = machine(id) else { return .refused("There is no such machine.") }
        let controller = controller(for: id)
        guard controller.state.allowsSuspend else { return .refused("“\(config.name)” is not running.") }
        // A message left from an earlier request must not read as this one's failure.
        controller.errorMessage = nil
        await controller.suspend()
        return Self.result(of: controller) { $0 == .stopped }
    }

    /// Stops a machine and returns: a forced stop once the machine is released, a clean shutdown as soon as the guest was asked
    /// (it powers off in its own time; its state says when).
    func stopAndWait(_ id: UUID, force: Bool) async -> MachineCommandResult {
        guard let config = machine(id) else { return .refused("There is no such machine.") }
        let controller = controller(for: id)
        guard controller.state.isActive else { return .refused("“\(config.name)” is not running.") }
        controller.errorMessage = nil
        if force {
            await controller.forceStop()
            return Self.result(of: controller) { $0 == .stopped }
        }
        controller.requestStop()
        return Self.result(of: controller) { $0 == .shuttingDown || $0 == .stopped }
    }

    /// The machine reached the state the request wanted: done, whatever notice the controller holds. Otherwise its message is
    /// the failure; without one, the state it is in.
    static func result(of controller: VMController, reached wanted: (MachineState) -> Bool) -> MachineCommandResult {
        if wanted(controller.state) { return .done(controller.state) }
        if let message = controller.errorMessage { return .failed(message) }
        return .done(controller.state)
    }
}
