public import Foundation

/// What a headless helper boots: one Linux guest, described in JSON and read from a path or from standard input.
///
/// The descriptor is the only input the helper trusts the launcher with, and the sandbox profile is generated from it,
/// so every path in it is checked (`SandboxPath`) before it reaches a profile, an entitlement or the framework.
public struct HelperDescriptor: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let nameLimit = 64

    public var version: Int
    public var name: String
    public var cpuCount: Int
    public var memoryMiB: Int
    public var boot: Boot
    public var disks: [Disk]
    /// An installation ISO, attached as a read-only USB mass-storage device.
    public var installerISO: String?
    public var network: Network

    public struct Boot: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// UEFI firmware boots the disks and the ISO; `variableStore` holds its variables.
            case efi
            /// The framework loads `kernel` (and `initrd`) directly.
            case kernel
        }

        public var kind: Kind
        /// EFI only: the variable store, created by the helper when the file does not exist and the machine starts.
        public var variableStore: String?
        /// Kernel only.
        public var kernel: String?
        public var initrd: String?
        public var commandLine: String?

        public init(kind: Kind, variableStore: String? = nil, kernel: String? = nil, initrd: String? = nil, commandLine: String? = nil) {
            self.kind = kind
            self.variableStore = variableStore
            self.kernel = kernel
            self.initrd = initrd
            self.commandLine = commandLine
        }
    }

    public struct Disk: Codable, Equatable, Sendable {
        public var path: String
        public var readOnly: Bool

        public init(path: String, readOnly: Bool = false) {
            self.path = path
            self.readOnly = readOnly
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        }
    }

    public enum Network: String, Codable, Sendable {
        /// No network card.
        case none
        /// The framework's NAT attachment; its per-machine service does the networking, not the helper.
        case nat
        /// A virtio card on one end of a datagram socket pair; the helper holds the other end. The spike runs no stack on
        /// it, so the guest sees a link that goes nowhere; it exists to show that the attachment works inside a sandbox.
        case fileHandle
    }

    public init(
        version: Int = Self.currentVersion, name: String, cpuCount: Int = 2, memoryMiB: Int = 1024, boot: Boot, disks: [Disk] = [],
        installerISO: String? = nil, network: Network = .none
    ) {
        self.version = version
        self.name = name
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.boot = boot
        self.disks = disks
        self.installerISO = installerISO
        self.network = network
    }

    /// `version`, `name` and `boot` are required; everything else has the default the memberwise initializer has.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        cpuCount = try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 2
        memoryMiB = try container.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? 1024
        boot = try container.decode(Boot.self, forKey: .boot)
        disks = try container.decodeIfPresent([Disk].self, forKey: .disks) ?? []
        installerISO = try container.decodeIfPresent(String.self, forKey: .installerISO)
        network = try container.decodeIfPresent(Network.self, forKey: .network) ?? .none
    }

    // MARK: Reading

    /// The descriptor in `data`, checked. A malformed or unacceptable one is `HelperFailure.invalidDescriptor`.
    public static func parse(_ data: Data) throws -> Self {
        let descriptor: Self
        do {
            descriptor = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw HelperFailure.invalidDescriptor("the descriptor is not valid JSON for this helper: \(error.localizedDescription)")
        }
        try descriptor.validate()
        return descriptor
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw HelperFailure.invalidDescriptor(
                "unsupported descriptor version \(version); this helper reads version \(Self.currentVersion)")
        }
        guard !name.isEmpty, name.count <= Self.nameLimit,
            name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
        else {
            throw HelperFailure.invalidDescriptor("the name must be 1 to \(Self.nameLimit) printable characters")
        }
        guard cpuCount >= 1, memoryMiB >= 1 else {
            throw HelperFailure.invalidDescriptor("cpuCount and memoryMiB must be positive")
        }
        switch boot.kind {
        case .efi:
            guard boot.variableStore != nil else { throw HelperFailure.invalidDescriptor("an efi boot needs a variableStore") }
            guard boot.kernel == nil, boot.initrd == nil, boot.commandLine == nil else {
                throw HelperFailure.invalidDescriptor("kernel, initrd and commandLine belong to a kernel boot, not an efi boot")
            }
        case .kernel:
            guard boot.kernel != nil else { throw HelperFailure.invalidDescriptor("a kernel boot needs a kernel") }
            guard boot.variableStore == nil else {
                throw HelperFailure.invalidDescriptor("variableStore belongs to an efi boot, not a kernel boot")
            }
        }
        guard !disks.isEmpty || installerISO != nil else {
            throw HelperFailure.invalidDescriptor("the machine needs a disk or an installerISO to boot from")
        }
        for path in readPaths + readWritePaths {
            try SandboxPath.validate(path)
        }
    }

    // MARK: Paths

    /// Files the helper only reads: the ISO, the kernel and the initial ramdisk, and read-only disks.
    public var readPaths: [String] {
        var paths = disks.filter(\.readOnly).map(\.path)
        paths += [installerISO, boot.kernel, boot.initrd].compactMap(\.self)
        return Self.unique(paths)
    }

    /// Files the helper reads and writes: disks that are not read-only, and the EFI variable store.
    public var readWritePaths: [String] {
        Self.unique(disks.filter { !$0.readOnly }.map(\.path) + [boot.variableStore].compactMap(\.self))
    }

    private static func unique(_ paths: [String]) -> [String] {
        Array(Set(paths)).sorted()
    }

    /// The descriptor with each path resolved through symbolic links (a sandbox matches the real path, and `/tmp` is a link
    /// to `/private/tmp`). A file that does not exist yet is resolved through its directory.
    public func canonicalized() throws -> Self {
        func resolve(_ path: String) throws -> String {
            let resolved: String
            if let real = SandboxPath.realPath(path) {
                resolved = real
            } else {
                let url = URL(filePath: path)
                guard let directory = SandboxPath.realPath(url.deletingLastPathComponent().path) else { return path }
                resolved = directory == "/" ? "/" + url.lastPathComponent : directory + "/" + url.lastPathComponent
            }
            try SandboxPath.validate(resolved)
            return resolved
        }
        var copy = self
        copy.boot.variableStore = try boot.variableStore.map(resolve)
        copy.boot.kernel = try boot.kernel.map(resolve)
        copy.boot.initrd = try boot.initrd.map(resolve)
        copy.installerISO = try installerISO.map(resolve)
        copy.disks = try disks.map { Disk(path: try resolve($0.path), readOnly: $0.readOnly) }
        return copy
    }
}

/// The paths a sandbox is asked to allow. They end up inside a profile and inside a signature, so they are plain,
/// absolute, normalised file names or nothing.
public enum SandboxPath {
    public static let lengthLimit = 1024

    /// Refuses a path that is not absolute or not normalised, or that holds a character able to end a quoted string or
    /// truncate the path: a quote, a backslash, or any control character (a newline and a NUL included).
    /// Parentheses, semicolons and spaces are harmless inside the quoted string a profile puts a path in, and are accepted.
    public static func validate(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= lengthLimit else {
            throw HelperFailure.invalidDescriptor("path \(describe(path)) must be absolute and at most \(lengthLimit) bytes")
        }
        guard path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0 != "\"" && $0 != "\\" }) else {
            throw HelperFailure.invalidDescriptor("path \(describe(path)) holds a quote, a backslash or a control character")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.isEmpty, components != [""] else {
            throw HelperFailure.invalidDescriptor("the root directory cannot be granted")
        }
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HelperFailure.invalidDescriptor("path \(describe(path)) must not hold empty, '.' or '..' components")
        }
    }

    /// `realpath(3)`: the path with every symbolic link resolved (unlike `URL.resolvingSymlinksInPath`, which turns
    /// `/private/tmp` back into `/tmp`), or `nil` when it does not exist.
    public static func realPath(_ path: String) -> String? {
        // `realpath` allocates the result with malloc when the second argument is nil; it is copied and freed here.
        guard let resolved = unsafe realpath(path, nil) else { return nil }
        defer { unsafe free(resolved) }
        return unsafe String(cString: resolved)
    }

    /// The path with control characters made visible, for an error message.
    static func describe(_ path: String) -> String {
        let shown = path.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? "\\u{\(String($0.value, radix: 16))}" : String($0) }
        return "'" + shown.joined() + "'"
    }
}
