import Foundation

/// The words alerts and tooltips use for a machine, by what it runs: a virtual machine keeps the wording it always had, and a
/// container is called a container.
enum MachineWording {
    /// The start of the report the machine state makes when a machine stops by itself with an error.
    static let virtualMachineStoppedPrefix = "The virtual machine stopped: "

    static func errorTitle(for workload: WorkloadKind) -> String {
        workload == .container ? "Container Error" : "Virtual Machine Error"
    }

    static func startHelp(for workload: WorkloadKind, hasSavedState: Bool) -> String {
        if workload == .container { return "Start the container" }
        return hasSavedState ? "Resume from suspended state" : "Start the virtual machine"
    }

    /// `message` as the user should read it for a machine that runs `workload`: the report of a machine that stopped by itself
    /// names a container as one; any other report is already neutral.
    static func report(_ message: String, for workload: WorkloadKind) -> String {
        guard workload == .container, message.hasPrefix(virtualMachineStoppedPrefix) else { return message }
        return "The container stopped: " + message.dropFirst(virtualMachineStoppedPrefix.count)
    }

    /// What the delete dialog says is removed.
    static func deleteDetail(for workload: WorkloadKind) -> String {
        workload == .container
            ? "The machine's folder, with the container's working files and image cache, is permanently removed."
            : "The virtual disk and all its contents are permanently removed."
    }

    /// The title of the alert shown when the app quits while machines run.
    static func quitTitle(virtualMachines: Int, containers: Int) -> String {
        let total = virtualMachines + containers
        let noun =
            containers == 0 ? "virtual machine" : virtualMachines == 0 ? "container" : "machine"
        return "\(total) \(noun)\(total == 1 ? " is" : "s are") still running."
    }

    /// What quitting does to the machines that run, which differs for a container: it is asked to stop, not cut off.
    static func quitDetail(virtualMachines: Int, containers: Int) -> String {
        let virtualMachineText =
            "Quitting force-stops them, like pulling the power cord. Suspend or shut them down first to avoid data loss."
        guard containers > 0 else { return virtualMachineText }
        let containerText = "Quitting asks each container to stop, and kills it if it has not ended after 5 seconds."
        guard virtualMachines > 0 else { return containerText }
        return "Quitting force-stops the virtual machines, like pulling the power cord. Suspend or shut them down first to avoid "
            + "data loss. " + containerText
    }
}
