/// The identity of a guest-initiated flow: fixed size, no heap, cheap to hash. The guest address is implied.
struct FlowKey: Hashable, Sendable {
    let guestPort: UInt16
    let remotePort: UInt16
    let remoteAddress: UInt32
}
