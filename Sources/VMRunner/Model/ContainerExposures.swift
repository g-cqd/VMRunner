import Foundation

extension VMConfig {
    /// What a container machine exposes. The virtual machine's channels (a NAT network, shared folders, extra disks, the
    /// clipboard, sound and the rest) do not exist for it, so none of them is listed; the lines say what does apply and what
    /// does not. A container is not claimed to be as isolated as a virtual machine of this app.
    var containerExposures: [Exposure] {
        var items = [
            Exposure(
                level: .medium,
                text: "Isolation: the container runs in its own lightweight Linux virtual machine, started by ContainerRunner, a "
                    + "separate helper process that is not sandboxed and is signed with the virtualization entitlement only. "
                    + "Do not treat it as equal to a virtual machine of this app."),
            Exposure(
                level: .medium,
                text: "Image: ContainerRunner pulls \(container?.image ?? ContainerSpec.defaultImage) from its registry over the "
                    + "network and runs what it contains. An image is code from outside this Mac; run only images you trust."),
            containerNetworkExposure,
            Exposure(
                level: .none,
                text: "This app's network policy, filtered network, shared folders and security profiles do not apply to a "
                    + "container."),
        ]
        if agentAccess {
            items.append(agentAccessExposure)
            items.append(containerOutputExposure)
        }
        return items
    }

    /// The control service can read the container's output to anyone who holds a token with the log capability.
    private var containerOutputExposure: Exposure {
        Exposure(
            level: .low,
            text: "Container output: a script or AI agent whose control token has the log capability can read the last 64 KiB of "
                + "what this container printed while the control service is on.")
    }

    private var containerNetworkExposure: Exposure {
        switch container?.network ?? .none {
        case .none:
            Exposure(level: .none, text: "Network: none for the container.")
        case .loopback:
            Exposure(
                level: .low,
                text: "Network: loopback only. The container has a network device that leads nowhere outside this Mac; it "
                    + "cannot reach your network or the internet.")
        }
    }
}
