import Foundation
import VirtioGPU
import Virtualization

/// The framework's queue element as the library serves it. Reading and writing copy once; giving the element back is the one
/// call that tells the guest it is used, and the library makes it exactly once.
@available(macOS 27.0, *)
struct FrameworkQueueElement: QueueElement {
    private let element: VZVirtioQueueElement

    init(_ element: VZVirtioQueueElement) {
        self.element = element
    }

    var readableByteCount: Int { element.readBuffersAvailableByteCount }
    var writableByteCount: Int { element.writeBuffersAvailableByteCount }

    func read(count: Int) throws -> [UInt8] {
        [UInt8](try element.readBytes(withExactLength: count))
    }

    func write(_ bytes: [UInt8]) throws {
        try element.write(Data(bytes))
    }

    func giveBack() {
        element.returnToQueue()
    }
}
