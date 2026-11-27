import Foundation
import NetPolicy

/// `config.json` is data from disk, which a copied or downloaded bundle controls, so it is checked where it enters the app
/// and rejected, never clamped: a value that is out of range means the file is not one this app wrote.
extension VMConfig {
    /// The largest `config.json` the app reads. A real one is a few kilobytes.
    static let maxFileBytes = 1 << 20
    /// How deeply arrays and objects may nest. A real config nests about six levels.
    static let maxNesting = 32

    /// Reads and decodes a config file, refusing one over `maxFileBytes` without reading the rest of it.
    static func load(from file: URL) throws -> VMConfig {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // One byte past the limit is enough to know the file is too large.
        return try decode(from: try handle.read(upToCount: maxFileBytes + 1) ?? Data())
    }

    /// Rejects data too large or too deeply nested to parse safely, before any parser sees it.
    static func checkBounds(of data: Data) throws {
        guard data.count <= maxFileBytes else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The configuration is larger than 1 MiB"))
        }
        guard !JSONNesting.exceeds(maxNesting, in: data) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "The configuration nests more than \(maxNesting) levels deep"))
        }
    }

    /// Throws `DecodingError.dataCorrupted` for a value outside the ranges the editor offers, a host path that isn't
    /// absolute (a relative path would depend on the directory the app happened to start in), and a text or a list longer
    /// than the editor lets anyone make it (`EditorLimits`). The editor enforces the same bounds, so it can't write what
    /// this refuses.
    func validate() throws {
        try validateText()
        try validateHostPaths()
        try validateRules()
        try validateVsockForwards()
        try validateContainer()
        try validateGuest()
        try Self.require(diskGiB, in: 1...EditorLimits.maxDiskGiB, "diskGiB")
        try Self.require(displayWidth, in: EditorLimits.displayWidth, "displayWidth")
        try Self.require(displayHeight, in: EditorLimits.displayHeight, "displayHeight")
        try Self.require(pixelsPerInch, in: EditorLimits.pixelsPerInch, "pixelsPerInch")
        try Self.require(pixelsPerPoint, in: EditorLimits.pixelsPerPoint, "pixelsPerPoint")
        try Self.require(maxRuntimeMinutes, in: EditorLimits.runtimeMinutes, "maxRuntimeMinutes")
        if let lastDisplayWidth { try Self.require(lastDisplayWidth, in: EditorLimits.displayWidth, "lastDisplayWidth") }
        if let lastDisplayHeight { try Self.require(lastDisplayHeight, in: EditorLimits.displayHeight, "lastDisplayHeight") }
    }

    private func validateText() throws {
        try Self.requireLength(name, "name")
        try Self.requireLength(provisioning.fullName, "provisioning.fullName")
        try Self.requireLength(provisioning.username, "provisioning.username")
        if let guestVersion { try Self.requireLength(guestVersion, "guestVersion") }
        if let macAddress { try Self.requireLength(macAddress, "macAddress") }
        if diskSerial.utf8.count > EditorLimits.maxDiskSerialLength || !diskSerial.allSatisfy(\.isASCII) {
            throw Self.corrupted("diskSerial", "must be at most \(EditorLimits.maxDiskSerialLength) ASCII characters")
        }
    }

    private func validateHostPaths() throws {
        try Self.requireCount(sharedFolders.count, "sharedFolders")
        try Self.requireCount(extraDisks.count, "extraDisks")
        for folder in sharedFolders { try Self.requirePath(folder.path, "sharedFolders") }
        for disk in extraDisks {
            try Self.requirePath(disk.path, "extraDisks")
            if AppPaths.isInside(URL(filePath: disk.path), AppPaths.machines) {
                throw Self.corrupted("extraDisks", "must not name a file inside the Machines folder")
            }
        }
        if let installerISO { try Self.requirePath(installerISO, "installerISO") }
        if let driverDiscPath {
            try Self.requirePath(driverDiscPath, "driverDiscPath")
            if AppPaths.isInside(URL(filePath: driverDiscPath), AppPaths.machines) {
                throw Self.corrupted("driverDiscPath", "must not name a file inside the Machines folder")
            }
        }
        if !provisioningSpecPath.isEmpty { try Self.requirePath(provisioningSpecPath, "provisioningSpecPath") }
        if case .local(let path) = source { try Self.requirePath(path, "source") }
    }

    /// Each rule list holds at most `maxRulesPerList` rules of at most `maxRuleLength` characters, measured on the text the
    /// policy stores, which is also what `NetworkPolicy.add` measures.
    private func validateVsockForwards() throws {
        guard vsockForwards.count <= EditorLimits.maxVsockForwards else {
            throw Self.corrupted("vsockForwards", "must hold at most \(EditorLimits.maxVsockForwards) ports")
        }
        guard vsockForwards.allSatisfy(EditorLimits.vsockPorts.contains) else {
            throw Self.corrupted("vsockForwards", "must hold ports from 1 to \(EditorLimits.vsockPorts.upperBound)")
        }
        guard Set(vsockForwards).count == vsockForwards.count else {
            throw Self.corrupted("vsockForwards", "must not repeat a port")
        }
    }

    private func validateRules() throws {
        for list in PolicyList.allCases {
            let rules = networkPolicy.rules(in: list)
            guard rules.count <= EditorLimits.maxRulesPerList else {
                throw Self.corrupted("networkPolicy.\(list.rawValue)", "must hold at most \(EditorLimits.maxRulesPerList) rules")
            }
            guard rules.allSatisfy({ $0.utf8.count <= EditorLimits.maxRuleLength }) else {
                throw Self.corrupted(
                    "networkPolicy.\(list.rawValue)", "must hold rules of at most \(EditorLimits.maxRuleLength) characters")
            }
        }
    }

    /// A Windows machine has none of the Linux-only features: a stored value that turns one on is refused, as a value out of
    /// range is. Nested virtualization is allowed: the generic platform offers it to Windows as to Linux. Shared folders and
    /// the clipboard setting are not refused: the first is guest-neutral, and the standard security profile sets the second on
    /// every guest, where nothing but a Linux machine acts on it. Its installation media is a file on this Mac: the app never
    /// downloads Windows, so a remote or catalog source is refused.
    private func validateGuest() throws {
        guard guest == .windows else { return }
        if let source {
            guard case .local = source else { throw Self.corrupted("source", "must be a local file for a Windows machine") }
        }
        let linuxOnly: [(key: String, isOn: Bool)] = [
            ("gpu", gpu != .apple), ("rosetta", rosetta), ("serialConsole", serialConsole), ("secureBoot", secureBoot),
            ("provisioningSpecPath", !provisioningSpecPath.isEmpty),
        ]
        if let refused = linuxOnly.first(where: \.isOn) { throw Self.corrupted(refused.key, "is not available for a Windows machine") }
    }

    /// A container machine's spec, within what the container runner accepts. A virtual machine ignores its `container`.
    private func validateContainer() throws {
        guard workload == .container else { return }
        guard let spec = container else { throw Self.corrupted("container", "is required for a container machine") }
        try Self.requireImage(spec.image)
        guard spec.command.count <= ContainerLimits.maxCommandElements else {
            throw Self.corrupted("container.command", "must hold at most \(ContainerLimits.maxCommandElements) elements")
        }
        for element in spec.command {
            guard element.utf8.count <= ContainerLimits.maxCommandElementBytes, !element.utf8.contains(0) else {
                throw Self.corrupted(
                    "container.command", "must hold elements of at most \(ContainerLimits.maxCommandElementBytes) bytes without NUL")
            }
        }
        try Self.requireEnvironment(spec.environment)
        try Self.require(spec.cpus, in: ContainerLimits.cpus, "container.cpus")
        try Self.require(spec.memoryMiB, in: ContainerLimits.memoryMiB, "container.memoryMiB")
    }

    private static func requireImage(_ image: String) throws {
        guard !image.isEmpty, image.utf8.count <= ContainerLimits.maxImageBytes else {
            throw corrupted("container.image", "must be from 1 to \(ContainerLimits.maxImageBytes) bytes")
        }
        guard !image.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }) else {
            throw corrupted("container.image", "must not hold whitespace or control characters")
        }
    }

    private static func requireEnvironment(_ environment: [ContainerEnvironmentEntry]) throws {
        guard environment.count <= ContainerLimits.maxEnvironmentEntries else {
            throw corrupted("container.environment", "must hold at most \(ContainerLimits.maxEnvironmentEntries) entries")
        }
        var seen = Set<String>()
        for entry in environment {
            guard entry.hasValidName else {
                throw corrupted(
                    "container.environment", "must name variables of letters, digits and underscores, not starting with a digit")
            }
            guard entry.hasValidValue else { throw corrupted("container.environment", "must hold values without NUL or newline") }
            guard entry.value.utf8.count <= ContainerLimits.maxEnvironmentValueBytes else {
                throw corrupted("container.environment", "must hold values of at most \(ContainerLimits.maxEnvironmentValueBytes) bytes")
            }
            guard seen.insert(entry.name).inserted else { throw corrupted("container.environment", "must not name \(entry.name) twice") }
        }
    }

    private static func require(_ value: Int, in range: ClosedRange<Int>, _ key: String) throws {
        guard range.contains(value) else {
            throw corrupted(key, "must be from \(range.lowerBound) to \(range.upperBound), not \(value)")
        }
    }

    private static func requirePath(_ path: String, _ key: String) throws {
        guard path.hasPrefix("/") else { throw corrupted(key, "must name absolute paths") }
        guard path.utf8.count <= EditorLimits.maxPathLength else {
            throw corrupted(key, "must name paths of at most \(EditorLimits.maxPathLength) bytes")
        }
    }

    private static func requireLength(_ text: String, _ key: String) throws {
        guard text.count <= EditorLimits.maxTextLength else {
            throw corrupted(key, "must be at most \(EditorLimits.maxTextLength) characters")
        }
    }

    private static func requireCount(_ count: Int, _ key: String) throws {
        guard count <= EditorLimits.maxHostItems else { throw corrupted(key, "must hold at most \(EditorLimits.maxHostItems) entries") }
    }

    private static func corrupted(_ key: String, _ problem: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [ConfigKey(key)], debugDescription: "\(key) \(problem)"))
    }

    private struct ConfigKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

enum JSONNesting {
    /// Whether arrays and objects nest deeper than `limit` in `data`. One pass over the bytes that tracks strings, so a
    /// bracket inside a string doesn't count, and stops as soon as the limit is passed.
    static func exceeds(_ limit: Int, in data: Data) -> Bool {
        var depth = 0
        var insideString = false
        var escaped = false
        for byte in data {
            if insideString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    insideString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                insideString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > limit { return true }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth = max(0, depth - 1)
            default:
                break
            }
        }
        return false
    }
}
