import Foundation

/// A release installed from GitHub into `.tools/`: where it is published and what its archive holds.
struct ReleaseSpec: Equatable, Sendable {
    /// The GitHub account that publishes the analyzer releases: the one place its name is written.
    static let analyzersOwner = "g-cqd"

    /// How a release archive is named and laid out. macOS's `tar` lists and unpacks every kind.
    enum Archive: Equatable, Sendable {
        /// `<name>-<version>-macos-arm64.tar.gz`, holding the binary in a directory named like the archive without its suffix.
        case versionedTarball
        /// A zip with a fixed file name that holds the binary at its root.
        case flatZip(name: String)
        /// A gzip tarball with the binary at its root, named by `template` where `{version}` stands for the version
        /// (`actionlint_{version}_darwin_arm64.tar.gz`); a template without it is a fixed name.
        case flatTarball(template: String)

        /// The compression letter of `tar`'s mode: gzip is asked for by name, a zip is recognised by `tar` itself.
        var tarCompression: String {
            switch self {
            case .versionedTarball, .flatTarball: "z"
            case .flatZip: ""
            }
        }
    }

    /// The program: the binary's file name, the prefix of its lock keys (uppercased) and of its install directory.
    let name: String
    let owner: String
    let repository: String
    /// What the release tag has in front of the version: `v` or nothing.
    let tagPrefix: String
    let archive: Archive

    /// `ARCLEAK_BIN`, `SWIFTLINT_BIN`, ...: use a binary of your own instead of the pinned release.
    var binaryOverrideVariable: String { "\(name.uppercased())_BIN" }

    func archiveName(version: String) -> String {
        switch archive {
        case .versionedTarball: "\(name)-\(version)-macos-arm64.tar.gz"
        case .flatZip(let fileName): fileName
        case .flatTarball(let template): template.replacing("{version}", with: version)
        }
    }

    /// The directory inside the archive that holds the binary, or nil when it sits at the archive's root.
    func directoryInArchive(version: String) -> String? {
        switch archive {
        case .versionedTarball: "\(name)-\(version)-macos-arm64"
        case .flatZip, .flatTarball: nil
        }
    }

    /// The portable SwiftLint release: a universal binary and its license in a flat zip.
    static let swiftlint = Self(
        name: "swiftlint", owner: "realm", repository: "SwiftLint", tagPrefix: "", archive: .flatZip(name: "portable_swiftlint.zip"))

    /// actionlint, the workflow linter: a tarball named for its version, the binary at its root.
    static let actionlint = Self(
        name: "actionlint", owner: "rhysd", repository: "actionlint", tagPrefix: "v",
        archive: .flatTarball(template: "actionlint_{version}_darwin_arm64.tar.gz"))
    /// zizmor, the workflow security auditor: a tarball with a fixed name, the binary at its root.
    static let zizmor = Self(
        name: "zizmor", owner: "zizmorcore", repository: "zizmor", tagPrefix: "v",
        archive: .flatTarball(template: "zizmor-aarch64-apple-darwin.tar.gz"))

    /// Every release `Scripts/analyzers.lock` pins, in the order `vmr analyzers versions` lists them.
    static var pinnedReleases: [Self] { AnalyzerTool.allCases.map(\.release) + [.swiftlint, .actionlint, .zizmor] }
}

/// The three static analyzers the gate runs.
enum AnalyzerTool: String, CaseIterable, Sendable {
    case arcleak
    case dolly
    case deadwood

    var release: ReleaseSpec {
        ReleaseSpec(name: rawValue, owner: ReleaseSpec.analyzersOwner, repository: rawValue, tagPrefix: "v", archive: .versionedTarball)
    }

    /// arcleak and deadwood gate with `--strict`. dolly is gated through `.dolly.json` instead (exact clones are
    /// errors, near and structural clones stay advisory), so it takes no `--strict`.
    var isStrict: Bool { self != .dolly }

    /// The tools `vmr analyzers baseline` rewrites when none is named: arcleak ships an empty baseline.
    static let baselineDefaults: [Self] = [.dolly, .deadwood]
}

/// One release pinned in `Scripts/analyzers.lock`.
struct AnalyzerPin: Equatable, Sendable {
    let release: ReleaseSpec
    /// The release tag without its prefix.
    let version: String
    /// The full commit SHA the tag points at. Informational: it is recorded so a human can compare it with the tag, and
    /// nothing checks it. The archive digest below is the only thing the installer verifies.
    let commit: String
    /// SHA-256 of the archive, verified before anything from it is listed, unpacked or run.
    let sha256: String

    var archiveName: String { release.archiveName(version: version) }
    var directoryInArchive: String? { release.directoryInArchive(version: version) }
}

/// The pins file: `KEY=VALUE` lines, `#` comments, keys `<TOOL>_VERSION`, `<TOOL>_COMMIT` and
/// `<TOOL>_SHA256_MACOS_ARM64`, for each analyzer, SwiftLint, actionlint and zizmor. The values end up in paths and addresses and decide
/// what is trusted, so a pin is rejected unless each has its exact shape, and a key written twice rejects the whole file.
struct AnalyzerLock: Equatable {
    static let relativePath = "Scripts/analyzers.lock"

    let values: [String: String]
    /// Keys the file assigns more than once, sorted.
    let duplicateKeys: [String]

    init(text: String) {
        var parsed: [String: String] = [:]
        var duplicates: Set<String> = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if parsed.updateValue(value, forKey: key) != nil { duplicates.insert(key) }
        }
        values = parsed
        duplicateKeys = duplicates.sorted()
    }

    static func load(root: URL) throws -> Self {
        let url = root.appending(path: relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ToolError("cannot read \(relativePath)") }
        return Self(text: text)
    }

    func pin(for tool: AnalyzerTool) throws -> AnalyzerPin {
        try pin(for: tool.release)
    }

    func pin(for release: ReleaseSpec) throws -> AnalyzerPin {
        guard duplicateKeys.isEmpty else {
            throw ToolError("\(Self.relativePath) assigns \(duplicateKeys.joined(separator: ", ")) more than once")
        }
        let prefix = release.name.uppercased()
        func value(_ field: String, shape: String, matching isValid: (String) -> Bool) throws -> String {
            guard let found = values["\(prefix)_\(field)"], !found.isEmpty else {
                throw ToolError("\(Self.relativePath) has no \(prefix)_\(field)")
            }
            guard isValid(found) else {
                throw ToolError("\(Self.relativePath): \(prefix)_\(field) '\(found)' is not \(shape)")
            }
            return found
        }
        return AnalyzerPin(
            release: release,
            version: try value("VERSION", shape: "a version ([0-9A-Za-z.+-]+)") { $0.allSatisfy { Self.versionCharacters.contains($0) } },
            commit: try value("COMMIT", shape: "40 lowercase hex digits") { Self.isHex($0, count: 40) },
            sha256: try value("SHA256_MACOS_ARM64", shape: "64 hex digits") { Self.isHex($0.lowercased(), count: 64) }.lowercased()
        )
    }

    private static let versionCharacters = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+-")

    private static func isHex(_ text: String, count: Int) -> Bool {
        // Bytes, not Characters: a digit with a combining mark is one Character but not a hex digit.
        text.utf8.count == count
            && text.utf8.allSatisfy {
                ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
            }
    }
}
