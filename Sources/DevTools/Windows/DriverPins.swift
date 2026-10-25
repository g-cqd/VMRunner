import Foundation

/// One driver disc the owner has checked and pinned.
struct DriverPin: Codable, Equatable, Sendable {
    /// The file's SHA-256, as 64 hexadecimal digits.
    let sha256: String
    let name: String
    let version: String
    /// Where the owner got the file and the date they checked it.
    let notes: String
}

/// The SHA-256 values pinned in `Resources/WindowsDriverPins.json`.
///
/// The file is `{"schema": 1, "about": "...", "entries": [{"sha256", "name", "version", "notes"}]}`. The list ships empty:
/// which discs to trust is the owner's decision, and an entry is added by the owner, with the source and the date of
/// the file they checked in `notes`.
struct DriverPins: Equatable, Sendable {
    static let schema = 1
    /// Where the list lives, relative to the package root.
    static let relativePath = "Resources/WindowsDriverPins.json"

    let entries: [DriverPin]

    private struct Document: Decodable {
        let schema: Int
        let entries: [DriverPin]
    }

    /// Reads and checks the list at `url`.
    /// - Throws: a `ToolError` with status `DriverVerifyStatus.listUnusable` if the file cannot be read or is not a valid list.
    static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolError("cannot read the pinned list \(url.path)", status: DriverVerifyStatus.listUnusable)
        }
        return try Self(parsing: data, source: url.path)
    }

    /// Checks `data` as a list: the schema number, a well-formed value in every entry, and no value twice.
    init(parsing data: Data, source: String) throws {
        func refuse(_ reason: String) -> ToolError {
            ToolError("the pinned list \(source) is malformed: \(reason)", status: DriverVerifyStatus.listUnusable)
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw refuse("it is not JSON of the documented shape")
        }
        guard document.schema == Self.schema else { throw refuse("schema \(document.schema), expected \(Self.schema)") }
        var seen: Set<String> = []
        for entry in document.entries {
            guard Self.isDigest(entry.sha256) else { throw refuse("\"\(entry.sha256)\" is not 64 hexadecimal digits") }
            guard seen.insert(entry.sha256.lowercased()).inserted else { throw refuse("\(entry.sha256) is listed twice") }
            guard !entry.name.isEmpty, !entry.version.isEmpty, !entry.notes.isEmpty else {
                throw refuse("the entry \(entry.sha256) needs a name, a version and notes (the source and the date checked)")
            }
        }
        entries = document.entries
    }

    /// The entry for `digest` (hexadecimal, any case), or nil.
    func entry(forDigest digest: String) -> DriverPin? {
        entries.first { $0.sha256.lowercased() == digest.lowercased() }
    }

    private static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64
            && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) }
    }
}

/// The exit statuses of `vmr windows drivers verify`: 0 matches, and one distinct status for each way it does not.
enum DriverVerifyStatus {
    /// The file is not in the pinned list.
    static let noMatch: Int32 = 1
    /// `sysexits.h` EX_DATAERR: the pinned list cannot be read or is malformed.
    static let listUnusable: Int32 = 65
    /// `sysexits.h` EX_NOINPUT: the file cannot be read, is a directory, or is not a regular file.
    static let fileUnreadable: Int32 = 66
}
