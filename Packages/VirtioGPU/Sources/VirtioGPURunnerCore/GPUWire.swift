/// What the guest sees of the device before any command: its virtio identity, its queues and the feature bits it offers
/// (virtio specification 1.3, section 5.7). Two-dimensional only: none of the 3D, EDID, blob or context feature bits.
package enum GPUWire {
    /// The virtio device ID of a GPU device.
    package static let deviceID: UInt16 = 16
    /// PCI class 0x03, display controller.
    package static let pciClassID: UInt8 = 0x03
    /// PCI subclass 0x80, "other display controller": the device is not VGA compatible.
    package static let pciSubclassID: UInt8 = 0x80
    /// The control queue and the cursor queue.
    package static let queueCount: UInt16 = 2
    package static let controlQueue: UInt16 = 0
    package static let cursorQueue: UInt16 = 1
    /// `VIRTIO_F_VERSION_1` is feature bit 32: bit 0 of the upper 32-bit half of the feature set.
    package static let versionOneFeatureSubset1: UInt32 = 1
    /// `VIRTIO_GPU_EVENT_DISPLAY`, set in `events_read` when the display configuration changed.
    package static let eventDisplay: UInt32 = 1
}

/// The device-specific configuration space of a virtio GPU (`struct virtio_gpu_config`): four little-endian 32-bit fields.
package struct GPUConfigSpace: Equatable, Sendable {
    package var eventsRead: UInt32
    package var eventsClear: UInt32
    package var scanoutCount: UInt32
    package var capsetCount: UInt32

    package init(eventsRead: UInt32, eventsClear: UInt32, scanoutCount: UInt32, capsetCount: UInt32) {
        self.eventsRead = eventsRead
        self.eventsClear = eventsClear
        self.scanoutCount = scanoutCount
        self.capsetCount = capsetCount
    }

    /// The 16 bytes the guest reads, in field order, each field little-endian.
    package var bytes: [UInt8] {
        [eventsRead, eventsClear, scanoutCount, capsetCount].flatMap { field in
            (0..<4).map { UInt8(truncatingIfNeeded: field >> ($0 * 8)) }
        }
    }
}
