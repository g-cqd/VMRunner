import Foundation
import Virtualization

extension VMConfig {
    /// Whether a start must give the network card a new address: none is stored (or it is not an address), or the machine
    /// is disposable and takes a fresh identity at each start.
    var needsNewMACAddress: Bool {
        macAddress.flatMap { VZMACAddress(string: $0) } == nil || (ephemeral && freshIdentityPerStart)
    }

    /// The bytes of a new machine identifier for this start of a disposable machine with a fresh identity; nil otherwise,
    /// and the machine keeps the identifier it was made with.
    func makeFreshMachineIdentity() -> Data? {
        guard ephemeral, freshIdentityPerStart else { return nil }
        return guest == .macOS ? VZMacMachineIdentifier().dataRepresentation : VZGenericMachineIdentifier().dataRepresentation
    }
}
