import VirtioGPU
import Virtualization

/// Guest RAM through a device's mapping, for the library's transfers. Each read maps the range the library asks for, checks that
/// the framework mapped all of it, and copies it out once: the guest may change its memory at any time, so only the copy is used.
@available(macOS 27.0, *)
struct GuestMemoryMapping: GuestMemoryReader {
    let device: VZCustomVirtioDevice

    func copyBytes(atPhysicalAddress address: UInt64, count: Int) -> [UInt8]? {
        if count <= 0 { return count == 0 ? [] : nil }
        guard let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: count) else { return nil }
        guard mapping.length >= count else { return nil }
        // The one unsafe read of guest memory: `count` bytes of a mapping that holds at least that many, copied into an array
        // while the mapping object is still alive (it is what holds the host memory the pointer points into).
        return withExtendedLifetime(mapping) {
            unsafe Array(UnsafeBufferPointer(start: mapping.mutableBytes.assumingMemoryBound(to: UInt8.self), count: count))
        }
    }
}
