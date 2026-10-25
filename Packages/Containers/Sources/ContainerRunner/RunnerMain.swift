import ContainerRunnerCore
import Foundation

/// What went wrong around the container, as a message the owner can paste into a report.
struct RunnerFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The runner's top level: make the scratch directory, get a verified kernel, run the container, print the report. With
/// `--json` the report is replaced by events on standard output, and standard input can stop the run.
enum RunnerMain {
    static func run(_ arguments: RunnerArguments) async -> Int32 {
        let layout = RunnerLayout(scratch: arguments.scratch)
        let events = arguments.json ? EventEmitter() : nil
        let stop = StopSignal {
            events?.send(RunnerEvent(.finished, status: RunnerStatus.stopped))
            exit(RunnerStatus.stopped)
        }
        if events != nil {
            // A launcher that went away must end the run through standard input, not kill the runner with a broken pipe.
            _ = signal(SIGPIPE, SIG_IGN)
            StdinWatcher(signal: stop).start()
        }
        var report = RunnerReport()
        do {
            try FileManager.default.createDirectory(
                at: layout.scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let log: ConsoleStream = events == nil ? .output : .error
            Console.line("scratch: \(layout.scratch.path)", to: log)
            let started = ContinuousClock.now
            let kernel = try await KernelProvider.ensureKernel(layout: layout, log: log)
            events?.send(RunnerEvent(.phase, name: "kernel", seconds: RunnerEvent.seconds(of: started.duration(to: .now))))
            try await ContainerFlow(layout: layout, arguments: arguments, events: events, stop: stop).run(kernel: kernel, report: &report)
        } catch {
            Console.line("error: \(error)", to: .error)
            events?.send(RunnerEvent(.error, message: "\(error)"))
        }
        if let events {
            events.send(RunnerEvent(.finished, status: report.processStatus))
        } else {
            // The report goes out even when the run failed half way: the phases that completed are part of the answer.
            for line in report.lines {
                Console.line(line)
            }
        }
        return report.processStatus
    }
}
