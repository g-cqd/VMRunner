import Foundation
import VirtioGPURunnerCore

/// The lines the runner writes go straight to the standard streams.
func line(_ text: String, error: Bool = false) {
    let handle = error ? FileHandle.standardError : FileHandle.standardOutput
    try? handle.write(contentsOf: Data((text + "\n").utf8))
}

let usage = """
    usage: VirtioGPURunner --describe
      --describe   print the virtio identity and the configuration space the guest sees
    The device needs macOS 27 or later.
    """

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }.joined(separator: " ")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments == ["--describe"] else {
    line(usage, error: !(arguments == ["--help"] || arguments == ["-h"]))
    exit(arguments == ["--help"] || arguments == ["-h"] ? 0 : 64)
}
guard #available(macOS 27.0, *) else {
    line("error: the custom virtio device needs macOS 27 or later", error: true)
    exit(69)
}
let space = GPUConfigSpace(eventsRead: 0, eventsClear: 0, scanoutCount: 1, capsetCount: 0)
line("device ID \(GPUWire.deviceID), PCI class \(GPUWire.pciClassID) subclass \(GPUWire.pciSubclassID)")
line("queues \(GPUWire.queueCount): control \(GPUWire.controlQueue), cursor \(GPUWire.cursorQueue)")
line("mandatory features: subset1 \(GPUWire.versionOneFeatureSubset1) (VIRTIO_F_VERSION_1); optional: none")
line("display event bit \(GPUWire.eventDisplay)")
line("configuration space: \(hex(space.bytes))")
exit(0)
