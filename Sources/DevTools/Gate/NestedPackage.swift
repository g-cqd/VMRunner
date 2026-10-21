import Foundation

/// A package of its own inside the repository, built and tested by the gate besides the root package. Its dependencies
/// stay out of the root package's graph; it builds into a scratch directory of its own under `.build-packages`, so it
/// never shares build products with the root.
struct NestedPackage: Equatable, Sendable {
    static let scratchRoot = ".build-packages"

    /// The directory holding its `Package.swift`, relative to the repository root, without a leading or trailing slash.
    let path: String

    /// The path with its slashes replaced, so two packages never share a scratch directory.
    var scratchPath: String { "\(Self.scratchRoot)/" + path.split(separator: "/").joined(separator: "-") }

    /// The `swift build` and `swift test` arguments that select this package and its scratch directory.
    var selection: [String] { ["--package-path", path, "--scratch-path", scratchPath] }

    /// Checks the configured `paths` against `root`.
    ///
    /// - Throws: ``ToolError`` for an empty, absolute or parent-relative path, a duplicate, or a directory without a
    ///   `Package.swift`.
    static func resolve(_ paths: [String], root: URL) throws -> [Self] {
        var packages: [Self] = []
        for configured in paths {
            let components = configured.split(separator: "/").filter { $0 != "." }
            guard !components.isEmpty, !configured.hasPrefix("/"), !components.contains("..") else {
                throw ToolError("packages in \(ProjectConfig.fileName): '\(configured)' must be a directory below the package root")
            }
            let package = Self(path: components.joined(separator: "/"))
            guard !packages.contains(package) else {
                throw ToolError("packages in \(ProjectConfig.fileName): '\(package.path)' is listed twice")
            }
            let manifest = root.appending(path: package.path).appending(path: "Package.swift")
            guard FileManager.default.fileExists(atPath: manifest.path) else {
                throw ToolError("packages in \(ProjectConfig.fileName): \(package.path) has no Package.swift")
            }
            packages.append(package)
        }
        return packages
    }
}
