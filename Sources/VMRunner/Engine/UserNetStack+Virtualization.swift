import Foundation
import NetPolicy
import NetStack
import Virtualization

extension UserNetStack {
    /// A user-mode network ready to plug into a virtual machine.
    struct Attachment {
        /// Install as `VZVirtioNetworkDeviceConfiguration.attachment`.
        let attachment: VZFileHandleNetworkDeviceAttachment
        /// Call ``UserNetStack/start()`` before starting the VM and ``UserNetStack/stop()`` after it ends.
        let stack: UserNetStack
    }

    /// Builds the attachment for a virtio NIC whose frames this stack handles.
    ///
    /// The guest-side descriptor is owned by the returned attachment's file handle; the host side by the stack. The
    /// attachment's MTU is set to `config.mtu`, which DHCP announces to the guest as well.
    ///
    /// - Throws: ``UserNetError``.
    static func attachment(
        config: UserNetConfig = UserNetConfig(), policy: NetworkPolicy = NetworkPolicy(),
        resolver: any HostNameResolver = SystemNameResolver(), pathChangeAction: ExistingFlowAction = .terminate,
        logger: any UserNetLogger = SilentUserNetLogger()
    ) throws(UserNetError) -> Attachment {
        let made = try make(
            config: config, policy: policy, resolver: resolver, pathChangeAction: pathChangeAction, logger: logger)
        let handle = FileHandle(fileDescriptor: made.guestDescriptor, closeOnDealloc: true)
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
        attachment.maximumTransmissionUnit = config.mtu
        return Attachment(attachment: attachment, stack: made.stack)
    }
}
