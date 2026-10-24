import VirtioGPURunnerCore
import Virtualization

/// Guest RAM through the device's mapping, copied out once: the guest may change its memory at any time, so the device
/// works only on the copy.
@available(macOS 27.0, *)
struct MappedGuestMemory: GuestMemoryReader {
    let device: VZCustomVirtioDevice

    func copyBytes(atPhysicalAddress address: UInt64, count: Int) -> [UInt8]? {
        guard count > 0 else { return count == 0 ? [] : nil }
        guard let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: count), mapping.length >= count else {
            return nil
        }
        // The framework maps at least `count` bytes of guest RAM from `address` (checked above); they are read once, here.
        let source = unsafe UnsafeRawBufferPointer(start: mapping.mutableBytes, count: count)
        return unsafe Array(source)
    }
}
