import Foundation
import VirtioGPURunnerCore
import Virtualization

/// One run: the scratch directory, the configuration, the machine, and the hard time limit after which the machine is
/// stopped whatever it does. SIGTERM and SIGINT end the run the same way, through the main queue. Everything runs on the main
/// queue (the framework's, the device's and the runner's).
@available(macOS 27.0, *)
@MainActor
final class RunnerMain: NSObject, VZVirtualMachineDelegate {
    private let options: RunnerOptions
    /// Held here because the device provider keeps its delegate weakly.
    private let device: GPUDevice
    private var machine: VZVirtualMachine?
    /// Set once the machine is being stopped, so a second request ends the run at once instead of waiting for it.
    private var stopping = false
    private var shutdownSignals: ShutdownSignals?

    init(options: RunnerOptions) {
        self.options = options
        let device = GPUDevice(probeConfigChangeSeconds: options.probeConfigChangeSeconds)
        var sinks: [any ScanoutSink] = []
        if options.headlessDump { sinks.append(ScanoutDump(path: options.scanoutPNGPath) { device.log($0) }) }
        if options.window { sinks.append(ScanoutWindow()) }
        device.sinks = sinks
        self.device = device
    }

    /// Builds and validates the configuration without writing a file or starting anything.
    func validate() throws {
        let configuration = try MachineBuilder.build(options, device: device, creatingFiles: false)
        try configuration.validate()
    }

    /// Creates the scratch directory, builds, validates and starts the machine, and arms the time limit.
    func start() throws {
        try FileManager.default.createDirectory(
            atPath: options.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pid = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        guard FileManager.default.createFile(atPath: options.pidPath, contents: pid, attributes: [.posixPermissions: 0o600]) else {
            throw RunnerFailure("cannot write \(options.pidPath)")
        }
        let configuration = try MachineBuilder.build(options, device: device, creatingFiles: true)
        try configuration.validate()
        let machine = VZVirtualMachine(configuration: configuration)
        machine.delegate = self
        self.machine = machine
        device.log("starting: \(options.cpuCount) CPUs, \(options.memoryMiB) MiB, limit \(options.maxSeconds) s")
        machine.start { result in
            MainActor.assumeIsolated {
                switch result {
                case .success: self.device.log("machine running")
                case .failure(let error): self.finish("the machine did not start: \(error.localizedDescription)", status: 1)
                }
            }
        }
        let sinks = device.sinks
        if !sinks.isEmpty {
            // Ends with the runner; the process ends with it in any case.
            Task { @MainActor [weak self, device] in
                while self != nil {
                    try? await Task.sleep(for: .milliseconds(50))
                    for sink in sinks { sink.tick(atMilliseconds: device.milliseconds) }
                }
            }
        }
        let limit = options.maxSeconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            self?.stopAtLimit()
        }
        shutdownSignals = ShutdownSignals { [weak self] number in self?.stopForSignal(number) }
    }

    private func stopAtLimit() {
        stop(because: "time limit reached", ended: "stopped at the time limit", status: 0)
    }

    /// SIGTERM or SIGINT: the orderly end of the time limit, so the record and the last picture are written. The exit status
    /// is 128 plus the signal's number, as a shell reports a process that a signal ended.
    private func stopForSignal(_ number: Int32) {
        let name = number == SIGINT ? "SIGINT" : "SIGTERM"
        stop(because: "\(name) received", ended: "stopped by \(name)", status: 128 + number)
    }

    /// Stops the machine, then writes the record and the last picture and ends the process. A second request while the
    /// machine is still stopping ends the run at once.
    private func stop(because reason: String, ended: String, status: Int32) {
        if stopping {
            finish("\(reason) again, not waiting for the machine", status: status)
            return
        }
        guard let machine else { return }
        stopping = true
        device.log("\(reason), stopping the machine")
        machine.stop { error in
            MainActor.assumeIsolated {
                self.finish(ended + (error.map { ": \($0.localizedDescription)" } ?? ""), status: status)
            }
        }
    }

    /// Writes the newest picture and the command record to `commands.log` (private), then ends the process.
    private func finish(_ text: String, status: Int32) {
        device.log(text)
        for sink in device.sinks { sink.finish() }
        let report = Data(device.report().utf8)
        if FileManager.default.createFile(atPath: options.commandsLogPath, contents: report, attributes: [.posixPermissions: 0o600]) {
            device.log("command record written to \(options.commandsLogPath)")
        } else {
            device.log("could not write \(options.commandsLogPath)")
        }
        exit(status)
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish("the guest stopped", status: 0) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated { finish("the machine stopped with an error: \(error.localizedDescription)", status: 1) }
    }
}
