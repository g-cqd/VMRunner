import ContainerSpikeCore
import Foundation

/// What went wrong around the container, as a message the owner can paste into a report.
struct SpikeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The spike's top level: make the scratch directory, get a verified kernel, run the container, print the report.
enum SpikeMain {
    static func run(_ arguments: SpikeArguments) async -> Int32 {
        let layout = SpikeLayout(scratch: arguments.scratch)
        var report = SpikeReport()
        do {
            try FileManager.default.createDirectory(
                at: layout.scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            Console.line("scratch: \(layout.scratch.path)")
            let kernel = try await KernelProvider.ensureKernel(layout: layout)
            try await ContainerFlow(layout: layout, network: arguments.network).run(kernel: kernel, report: &report)
        } catch {
            Console.line("error: \(error)", to: .error)
        }
        // The report goes out even when the run failed half way: the phases that completed are part of the answer.
        for line in report.lines {
            Console.line(line)
        }
        return report.processStatus
    }
}
