import ContainerRunnerCore
import Containerization
import ContainerizationExtras
import Foundation
import Virtualization

/// A network for the container library that is not a network: it hands out one interface whose virtual device is attached to
/// a ``LoopbackLink`` by a file handle, the same kind of attachment the app gives a guest in its filtered network mode. The
/// guest gets the address plan of the app's user-mode stack (198.18.0.2 behind the gateway 198.18.0.1), so plugging the real
/// stack in later changes what reads the link, not what the guest sees.
struct LoopbackNetwork: Network {
    private let link: LoopbackLink
    private var issuedTo: String?

    init(link: LoopbackLink) {
        self.link = link
    }

    mutating func createInterface(_ id: String) throws -> (any Interface)? {
        if let issuedTo { throw RunnerFailure("the loopback network has one interface and \(issuedTo) holds it") }
        issuedTo = id
        return LoopbackInterface(
            ipv4Address: try CIDRv4("\(NetworkVerdict.guestAddress)/24"),
            ipv4Gateway: try IPv4Address(NetworkVerdict.gatewayAddress),
            link: link)
    }

    mutating func releaseInterface(_ id: String) throws {
        if issuedTo == id { issuedTo = nil }
    }
}

/// The interface the container library configures inside the guest, and the device it asks the virtualization framework for.
private struct LoopbackInterface: Interface, VZInterface {
    let ipv4Address: CIDRv4
    let ipv4Gateway: IPv4Address?
    /// Left to the framework, which picks a locally administered address.
    let macAddress: MACAddress? = nil
    let link: LoopbackLink

    func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: link.guestHandle)
        attachment.maximumTransmissionUnit = Int(mtu)
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = attachment
        return device
    }
}
