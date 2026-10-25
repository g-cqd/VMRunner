import Foundation

/// What a machine runs: a virtual machine with its own kernel and disk, or one container started from an image.
enum WorkloadKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case vm, container

    var id: Self { self }
    var label: String { self == .vm ? "Virtual machine" : "Container" }
}

/// The network a container sees. A container never reaches beyond this Mac.
enum ContainerNetwork: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, loopback

    var id: Self { self }
    var label: String { self == .none ? "None" : "Loopback only" }
}

/// What the container runner accepts, so the editor, `VMConfig.validate()` and the runner's own checks cannot disagree.
enum ContainerLimits {
    static let maxImageBytes = 255
    static let maxCommandElements = 64
    static let maxCommandElementBytes = 4096
    static let maxEnvironmentEntries = 64
    static let maxEnvironmentValueBytes = 4096
    static let cpus = 1...16
    static let memoryMiB = 128...16384
}

/// One `NAME=value` setting of a container's environment. The spec keeps them as a list, so the order the user chose is the
/// order the container sees, and `VMConfig.validate()` refuses a name that appears twice.
struct ContainerEnvironmentEntry: Codable, Hashable, Sendable {
    var name: String
    var value: String

    /// A letter or an underscore, then letters, digits and underscores: ASCII only.
    var hasValidName: Bool {
        func isLetterOrUnderscore(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
        guard let first = name.utf8.first, isLetterOrUnderscore(first) else { return false }
        return name.utf8.dropFirst().allSatisfy { isLetterOrUnderscore($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// A value holds no NUL byte and no newline.
    var hasValidValue: Bool { !value.utf8.contains { $0 == 0 || $0 == UInt8(ascii: "\n") } }
}

/// How a container machine runs. A stored spec that lacks a key gets that key's default.
struct ContainerSpec: Codable, Hashable, Sendable {
    static let defaultImage = "docker.io/library/alpine:3.24.2"
    static let defaultCPUs = 2
    static let defaultMemoryMiB = 512

    var image = Self.defaultImage
    /// The program and its arguments, one element each, run without a shell. Empty means the runner's baseline command.
    var command: [String] = []
    var environment: [ContainerEnvironmentEntry] = []
    var cpus = Self.defaultCPUs
    var memoryMiB = Self.defaultMemoryMiB
    var network = ContainerNetwork.none

    init(
        image: String = Self.defaultImage, command: [String] = [], environment: [ContainerEnvironmentEntry] = [],
        cpus: Int = Self.defaultCPUs,
        memoryMiB: Int = Self.defaultMemoryMiB, network: ContainerNetwork = .none
    ) {
        self.image = image
        self.command = command
        self.environment = environment
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.network = network
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        image = try values.decodeIfPresent(String.self, forKey: .image) ?? Self.defaultImage
        command = try values.decodeIfPresent([String].self, forKey: .command) ?? []
        environment = try values.decodeIfPresent([ContainerEnvironmentEntry].self, forKey: .environment) ?? []
        cpus = try values.decodeIfPresent(Int.self, forKey: .cpus) ?? Self.defaultCPUs
        memoryMiB = try values.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? Self.defaultMemoryMiB
        network = try values.decodeIfPresent(ContainerNetwork.self, forKey: .network) ?? .none
    }
}
