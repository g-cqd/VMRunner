import Foundation

/// The three g-cqd static analyzers the gate runs.
enum AnalyzerTool: String, CaseIterable, Sendable {
    case arcleak
    case dolly
    case deadwood

    /// `ARCLEAK_BIN`, `DOLLY_BIN`, `DEADWOOD_BIN`: use a binary of your own instead of the pinned release.
    var binaryOverrideVariable: String { "\(rawValue.uppercased())_BIN" }

    /// arcleak and deadwood gate with `--strict`. dolly is gated through `.dolly.json` instead (exact clones are
    /// errors, near and structural clones stay advisory), so it takes no `--strict`.
    var isStrict: Bool { self != .dolly }

    /// The tools `vmr analyzers baseline` rewrites when none is named: arcleak ships an empty baseline.
    static let baselineDefaults: [Self] = [.dolly, .deadwood]
}

/// One analyzer release pinned in `Scripts/analyzers.lock`.
struct AnalyzerPin: Equatable, Sendable {
    let tool: AnalyzerTool
    /// The release tag without the leading `v`.
    let version: String
    /// The full commit SHA the tag points at; the CI workflow pins the same one.
    let commit: String
    /// SHA-256 of `<tool>-<version>-macos-arm64.tar.gz`, verified before anything from the archive runs.
    let sha256: String

    var archiveName: String { "\(tool.rawValue)-\(version)-macos-arm64.tar.gz" }
    var directoryInArchive: String { "\(tool.rawValue)-\(version)-macos-arm64" }
}

/// The pins file: `KEY=VALUE` lines, `#` comments, keys `<TOOL>_VERSION`, `<TOOL>_COMMIT` and
/// `<TOOL>_SHA256_MACOS_ARM64`.
struct AnalyzerLock: Equatable {
    static let relativePath = "Scripts/analyzers.lock"

    let values: [String: String]

    init(text: String) {
        var parsed: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            parsed[key] = value
        }
        values = parsed
    }

    static func load(root: URL) throws -> Self {
        let url = root.appending(path: relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ToolError("cannot read \(relativePath)") }
        return Self(text: text)
    }

    func pin(for tool: AnalyzerTool) throws -> AnalyzerPin {
        let prefix = tool.rawValue.uppercased()
        func value(_ field: String) throws -> String {
            guard let found = values["\(prefix)_\(field)"], !found.isEmpty else {
                throw ToolError("\(Self.relativePath) has no \(prefix)_\(field)")
            }
            return found
        }
        return AnalyzerPin(
            tool: tool,
            version: try value("VERSION"),
            commit: try value("COMMIT"),
            sha256: try value("SHA256_MACOS_ARM64").lowercased()
        )
    }
}
