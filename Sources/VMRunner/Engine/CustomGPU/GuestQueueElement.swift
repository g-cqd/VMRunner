import Foundation
import VirtioGPU
import Virtualization

/// A queue element of the framework, as the library serves it. Giving it back is the one call that tells the guest the element
/// is used, and the library makes it exactly once.
@available(macOS 27.0, *)
struct GuestQueueElement: QueueElement {
    let element: VZVirtioQueueElement

    var readableByteCount: Int { element.readBuffersAvailableByteCount }
    var writableByteCount: Int { element.writeBuffersAvailableByteCount }

    func read(count: Int) throws -> [UInt8] {
        let data = try element.readBytes(withExactLength: count)
        return Array(data)
    }

    func write(_ bytes: [UInt8]) throws {
        try element.write(Data(bytes))
    }

    func giveBack() {
        element.returnToQueue()
    }
}
