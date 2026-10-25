/// The bounds the device puts on what a guest may ask of it. The guest is untrusted: every count, size and length it sends is
/// checked against these before anything is allocated or copied.
package struct GPULimits: Equatable, Sendable {
    /// How many 2D resources may exist at once; one more is refused with an out-of-memory answer.
    package var maxResources = 256
    /// The largest host copy of one resource, in bytes (width × height × 4): 64 MiB, a 4096 × 4096 surface.
    package var maxResourceBytes = 64 << 20
    /// The host copies of all resources together, in bytes.
    package var maxTotalResourceBytes = 256 << 20
    /// The most guest memory pieces one resource's backing may list: a 64 MiB surface in 4 KiB pages.
    package var maxBackingEntries = 16_384
    /// The most rows a transfer of a rectangle narrower than its resource may copy. Such a transfer is read one span per row,
    /// so its cost grows with its rows rather than its bytes. The Linux driver's scanouts are at most 8192 rows high.
    package var maxTransferRows = 8192
    /// The size of the one display the device reports.
    package var displayWidth: UInt32 = 1280
    package var displayHeight: UInt32 = 800

    package init() {}

    /// The longest request the device reads: an attach-backing header followed by the most entries it accepts.
    package var maxCommandBytes: Int { GPUWireSize.attachBacking + GPUWireSize.memoryEntry * maxBackingEntries }
}
