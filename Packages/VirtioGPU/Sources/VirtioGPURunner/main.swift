import Foundation
import VirtioGPURunnerCore

/// The virtio identity and the configuration space the guest sees.
func describe() {
    let space = GPUConfigSpace(eventsRead: 0, eventsClear: 0, scanoutCount: 1, capsetCount: 0)
    Output.line("device ID \(GPUWire.deviceID), PCI class \(GPUWire.pciClassID) subclass \(GPUWire.pciSubclassID)")
    Output.line("queues \(GPUWire.queueCount): control \(GPUWire.controlQueue), cursor \(GPUWire.cursorQueue)")
    Output.line("mandatory features: subset1 \(GPUWire.versionOneFeatureSubset1) (VIRTIO_F_VERSION_1); optional: none")
    Output.line("display event bit \(GPUWire.eventDisplay)")
    Output.line("configuration space: \(Output.hex(space.bytes))")
}

let request: RunnerRequest
do {
    request = try RunnerArguments.parse(Array(CommandLine.arguments.dropFirst()), home: NSHomeDirectory())
} catch {
    Output.line("error: \(error)", error: true)
    Output.line(RunnerArguments.usage, error: true)
    exit(64)
}

switch request {
case .help:
    Output.line(RunnerArguments.usage)
case .describe:
    describe()
case .run(let options):
    guard #available(macOS 27.0, *) else {
        Output.line("error: the custom virtio device needs macOS 27 or later", error: true)
        exit(69)
    }
    let runner = RunnerMain(options: options)
    do {
        if options.dryRun {
            try runner.validate()
            Output.line("configuration valid")
            exit(0)
        }
        try runner.start()
    } catch {
        Output.line("error: \(error)", error: true)
        exit(1)
    }
    withExtendedLifetime(runner) { dispatchMain() }
}
