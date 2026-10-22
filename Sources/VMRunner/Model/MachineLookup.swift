import Foundation

/// How `--start <name or uuid>` picks a machine.
enum MachineLookup: Equatable {
    case found(UUID)
    case notFound
    /// Several machines carry the name, so no single one is meant.
    case ambiguous(count: Int)

    /// An exact id wins; otherwise the name must belong to exactly one machine. Names are not unique in the library, and
    /// starting whichever comes first would boot a machine the caller did not name.
    static func resolve(_ key: String, in machines: [VMConfig]) -> Self {
        if let id = UUID(uuidString: key), machines.contains(where: { $0.id == id }) { return .found(id) }
        let named = machines.filter { $0.name == key }
        switch named.count {
        case 0: return .notFound
        case 1: return .found(named[0].id)
        default: return .ambiguous(count: named.count)
        }
    }
}

/// What `--start` does with its argument: start a machine, or say why not.
enum LaunchStart: Equatable {
    case start(UUID)
    case refuse(LaunchRefusal)

    /// Resolves `key` and checks that the machine can be started at all. `settingUp` holds the machines that have a setup job in
    /// the library's table: one still running, unwinding after a cancel, or failed and waiting for a retry.
    static func decide(_ key: String, in machines: [VMConfig], settingUp: Set<UUID>) -> Self {
        switch MachineLookup.resolve(key, in: machines) {
        case .notFound:
            return .refuse(.notFound)
        case .ambiguous(let count):
            return .refuse(.ambiguous(count: count))
        case .found(let id):
            guard let machine = machines.first(where: { $0.id == id }) else { return .refuse(.notFound) }
            if settingUp.contains(id) { return .refuse(.settingUp(name: machine.name)) }
            if !machine.isProvisioned { return .refuse(.notSetUp(name: machine.name)) }
            return .start(id)
        }
    }
}

/// Why `--start` did not start a machine.
enum LaunchRefusal: Equatable {
    case notFound
    case ambiguous(count: Int)
    case settingUp(name: String)
    case notSetUp(name: String)

    /// For the alert: it names the machine, so the person who ran the command or opened the window sees which one and why.
    var message: String {
        switch self {
        case .notFound: "--start: no machine has that name or id."
        case .ambiguous(let count): "--start: \(count) machines have that name. Use the machine's id instead."
        case .settingUp(let name):
            "“\(name)” is not ready: its setup is still running or has failed, so --start did not start it."
        case .notSetUp(let name):
            "“\(name)” has not finished its setup, so --start did not start it. Choose Resume Setup on the machine first."
        }
    }

    /// For the log: no machine name, which the log would have to treat as private.
    var logReason: String {
        switch self {
        case .notFound: "no machine has that name or id"
        case .ambiguous(let count): "\(count) machines have that name; the id is needed"
        case .settingUp: "the machine is still being set up"
        case .notSetUp: "the machine has not finished its setup"
        }
    }
}
