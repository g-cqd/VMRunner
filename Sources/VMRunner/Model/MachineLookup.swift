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
