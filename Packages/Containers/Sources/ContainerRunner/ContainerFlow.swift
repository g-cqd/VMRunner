import ContainerRunnerCore
import Containerization
import ContainerizationOCI
import Foundation

/// The run flow of the package's sample command-line tool, in the order that tool uses: a kernel, a container manager that
/// pulls the init image, a pull of the image, create, start, wait, stop. It runs the requested command, `uname -a` unless
/// one was given, and records what each step cost. With a loopback network the baseline container also pings its gateway,
/// and the frames its network device delivered are reported. With an emitter every phase and every chunk of output is also
/// sent as an event, and a stop request ends the wait by stopping the container.
struct ContainerFlow {
    /// The init image, matched to the pinned package release: the guest and the host speak a versioned protocol.
    static let initReference = "ghcr.io/apple/containerization/vminit:0.52.1"
    /// How much of the container's output the runner keeps for the verdict when it streams events.
    static let capturedBytes = 64 * 1024

    let layout: RunnerLayout
    let arguments: RunnerArguments
    let events: EventEmitter?
    let stop: StopSignal

    private var network: RunnerArguments.Network { arguments.network }

    /// The container's command: the one asked for, else the baseline. The baseline ping has no reply to get, so the shell
    /// ends with status 0 regardless; the frames the ping caused are the result, not the ping's own status.
    private var command: [String] {
        guard arguments.command.isEmpty else { return arguments.command }
        switch network {
        case .none: return ["uname", "-a"]
        case .loopback: return ["/bin/sh", "-c", "uname -a; ping -c 1 -W 2 \(NetworkVerdict.gatewayAddress) >/dev/null 2>&1; exit 0"]
        }
    }

    /// Appends each completed phase to `report`, so a failure half way still tells how far the run got.
    func run(kernel: URL, report: inout RunnerReport) async throws {
        guard network == .loopback else {
            try await execute(kernel: kernel, link: nil, report: &report)
            return
        }
        let link = try LoopbackLink()
        let collector = Task {
            var seen: [FrameSummary] = []
            for await bytes in link.frames {
                if let frame = FrameSummary.parse(bytes) { seen.append(frame) }
            }
            return seen
        }
        var failure: (any Error)?
        do {
            try await execute(kernel: kernel, link: link, report: &report)
        } catch {
            failure = error
        }
        link.stop()
        report.frames = await collector.value
        report.networkVerdict = NetworkVerdict.evaluate(frames: report.frames)
        if let failure { throw failure }
    }

    private func execute(kernel: URL, link: LoopbackLink?, report: inout RunnerReport) async throws {
        let clock = ContinuousClock()
        var started = clock.now
        func finishPhase(_ name: String) {
            let duration = started.duration(to: clock.now)
            report.phases.append(.init(name: name, duration: duration))
            events?.send(RunnerEvent(.phase, name: name, seconds: RunnerEvent.seconds(of: duration)))
            started = clock.now
        }

        var manager = try await ContainerManager(
            kernel: Kernel(path: kernel, platform: .linuxArm),
            initfsReference: Self.initReference,
            root: layout.imageStore,
            network: link.map { LoopbackNetwork(link: $0) }
        )
        finishPhase("init-image")

        let image = try await manager.imageStore.pull(reference: arguments.image, platform: Platform(from: "linux/arm64"))
        finishPhase("pull")

        let id = "runner-\(UUID().uuidString.prefix(8).lowercased())"
        let capture = OutputCapture(limit: events == nil ? .max : Self.capturedBytes)
        let memory = UInt64(arguments.memoryMiB) << 20
        let command = command
        let container = try await manager.create(
            id, image: image, rootfsSizeInBytes: UInt64(1) << 30, networking: link != nil,
            vm: VMResources(cpus: arguments.cpus, memoryInBytes: memory + VMResources.guestMemoryOverhead)
        ) { config in
            config.cpus = arguments.cpus
            config.memoryInBytes = memory
            config.process.arguments = command
            config.process.environmentVariables = arguments.environment(merging: config.process.environmentVariables)
            config.process.stdout = StreamWriter(capture: capture, stream: .stdout, emitter: events)
            config.process.stderr = StreamWriter(capture: capture, stream: .stderr, emitter: events)
        }
        finishPhase("create")

        do {
            try await container.create()
            finishPhase("boot")
            try await container.start()
            stop.settingUpDone()
            let status = try await waitForExit(of: container)
            finishPhase("run")
            try await container.stop()
            report.stopped = stop.isRequested
            if let status {
                events?.send(RunnerEvent(.exited, status: status.exitCode))
                report.output = capture.text
                report.exitCode = status.exitCode
                report.verdict = RunnerVerdict.evaluate(
                    exitCode: status.exitCode, output: capture.text, checksArchitecture: arguments.command.isEmpty)
            }
        } catch {
            try? await container.stop()
            Console.line("boot log kept at \(layout.imageStore.path)/containers/\(id)/bootlog.log", to: .error)
            throw error
        }
        do {
            try manager.delete(id)
        } catch {
            Console.line("warning: could not remove container \(id): \(error)", to: .error)
        }
    }

    /// Waits for the container's process. A stop request stops the container meanwhile, so the wait then ends with the
    /// status the process left, or with nil when it left none.
    private func waitForExit(of container: LinuxContainer) async throws -> ExitStatus? {
        let stop = stop
        return try await withThrowingTaskGroup(of: ExitStatus?.self) { group in
            group.addTask {
                do {
                    return try await container.wait()
                } catch  where stop.isRequested {
                    return nil
                }
            }
            group.addTask {
                await stop.requested()
                if !Task.isCancelled { try? await container.stop() }
                return nil
            }
            defer { group.cancelAll() }
            for try await status in group where status != nil { return status }
            return nil
        }
    }
}
