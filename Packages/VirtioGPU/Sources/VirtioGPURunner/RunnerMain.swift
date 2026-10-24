import Foundation
import VirtioGPURunnerCore
import Virtualization

/// One run: the scratch directory, the configuration, the machine, and the hard time limit after which the machine is
/// stopped whatever it does. Everything runs on the main queue (the framework's, the device's and the runner's).
@available(macOS 27.0, *)
@MainActor
final class RunnerMain: NSObject, VZVirtualMachineDelegate {
    private let options: RunnerOptions
    /// Held here because the device provider keeps its delegate weakly.
    private let device: GPUDevice
    private var machine: VZVirtualMachine?

    init(options: RunnerOptions) {
        self.options = options
        device = GPUDevice(probeConfigChangeSeconds: options.probeConfigChangeSeconds)
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
        let limit = options.maxSeconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            self.stopAtLimit()
        }
    }

    private func stopAtLimit() {
        guard let machine else { return }
        device.log("time limit reached, stopping the machine")
        machine.stop { error in
            MainActor.assumeIsolated {
                self.finish("stopped at the time limit" + (error.map { ": \($0.localizedDescription)" } ?? ""), status: 0)
            }
        }
    }

    /// Writes the command record to `commands.log` (private), then ends the process.
    private func finish(_ text: String, status: Int32) {
        device.log(text)
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
