import Foundation

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

    /// Throws `DecodingError.dataCorrupted` for a value outside the ranges the editor offers, and for a host path that
    /// isn't absolute (a relative path would depend on the directory the app happened to start in).
    func validate() throws {
        try Self.require(diskGiB, in: 1...EditorLimits.maxDiskGiB, "diskGiB")
        try Self.require(displayWidth, in: EditorLimits.displayWidth, "displayWidth")
        try Self.require(displayHeight, in: EditorLimits.displayHeight, "displayHeight")
        try Self.require(pixelsPerInch, in: EditorLimits.pixelsPerInch, "pixelsPerInch")
        try Self.require(pixelsPerPoint, in: EditorLimits.pixelsPerPoint, "pixelsPerPoint")
        try Self.require(maxRuntimeMinutes, in: EditorLimits.runtimeMinutes, "maxRuntimeMinutes")
        if let lastDisplayWidth { try Self.require(lastDisplayWidth, in: EditorLimits.displayWidth, "lastDisplayWidth") }
        if let lastDisplayHeight { try Self.require(lastDisplayHeight, in: EditorLimits.displayHeight, "lastDisplayHeight") }
        for folder in sharedFolders { try Self.requireAbsolute(folder.path, "sharedFolders") }
        for disk in extraDisks {
            try Self.requireAbsolute(disk.path, "extraDisks")
            if AppPaths.isInside(URL(filePath: disk.path), AppPaths.machines) {
                throw Self.corrupted("extraDisks", "must not name a file inside the Machines folder")
            }
        }
        if let installerISO { try Self.requireAbsolute(installerISO, "installerISO") }
    }

    private static func require(_ value: Int, in range: ClosedRange<Int>, _ key: String) throws {
        guard range.contains(value) else {
            throw corrupted(key, "must be from \(range.lowerBound) to \(range.upperBound), not \(value)")
        }
    }

    private static func requireAbsolute(_ path: String, _ key: String) throws {
        guard path.hasPrefix("/") else { throw corrupted(key, "must name absolute paths") }
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
