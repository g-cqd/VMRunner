import Foundation

/// What the machine controller and the provisioner need from the library of machines, and nothing more: where a machine's
/// bundle is, a way to store a changed configuration, and a way to record the host paths the user approved. They depend on
/// this, so neither needs the library (its list, its alerts, its controllers) and a test can stand in for it.
@MainActor
protocol MachineStore: AnyObject {
    /// The bundle of the machine with this id, whether or not it exists on disk yet.
    func bundle(_ id: UUID) -> VMBundle

    /// Stores a changed configuration of a machine the store knows; an unknown id is ignored.
    func update(_ config: VMConfig)

    /// Records that the user chose these paths for the machine. Call it only from what the user did, never from a
    /// settings change that may come from a file on disk.
    func approveHostPaths(_ grants: [HostPathGrant], for id: UUID)
}

extension VMLibrary: MachineStore {}
