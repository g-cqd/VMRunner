import Foundation
import Testing

@testable import DevTools

/// The packages of their own under `Packages/` against the root package: their dependencies stay out of the root's graph,
/// they share its safety settings, and the gate covers every one of them.
struct PackageLayoutTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// The directories under `Packages/` that hold a `Package.swift`.
    private static func nestedPackages() throws -> [String] {
        let directory = root.appending(path: "Packages")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().map { "Packages/\($0)" }.filter {
            FileManager.default.fileExists(atPath: root.appending(path: "\($0)/Package.swift").path)
        }
    }

    /// The lines between `// BEGIN shared settings` and `// END shared settings`.
    private static func sharedSettings(of manifest: String) -> [String]? {
        let lines = manifest.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("// BEGIN shared settings") }),
            let end = lines.firstIndex(where: { $0.hasPrefix("// END shared settings") }), begin < end
        else { return nil }
        return Array(lines[(begin + 1)..<end])
    }

    @Test
    func theRootPackageDoesNotKnowTheNestedOnes() throws {
        let manifest = try Self.text("Package.swift")
        let resolved = try Self.text("Package.resolved")
        #expect(!manifest.contains("containerization"), "the container library stays out of the root package")
        #expect(!resolved.contains("containerization"), "and out of its Package.resolved")
        #expect(!manifest.contains(".package(path:"), "the root depends on no nested package")
        for package in try Self.nestedPackages() {
            #expect(!manifest.contains(package), "the root manifest names the nested package \(package)")
        }
    }

    @Test
    func everyNestedPackageCopiesTheRootsSafetySettingsVerbatim() throws {
        let packages = try Self.nestedPackages()
        #expect(!packages.isEmpty)
        let shared = try #require(Self.sharedSettings(of: try Self.text("Package.swift")), "markers in the root Package.swift")
        #expect(shared.contains { $0.contains("strictMemorySafety") }, "the block holds the settings")
        for package in packages {
            let copy = try #require(Self.sharedSettings(of: try Self.text("\(package)/Package.swift")), "markers in \(package)")
            #expect(copy == shared, "\(package) drifted from the root's shared settings")
        }
    }

    @Test
    func theGateCoversEveryNestedPackageAndEachCommitsItsResolvedFile() throws {
        let config = try ProjectConfig.load(root: Self.root)
        let listed = try config.resolvedPackages(root: Self.root).map(\.path)
        #expect(listed == (try Self.nestedPackages()), "a package under Packages/ that .vmr.json does not list is never built")
        for package in listed {
            #expect(
                FileManager.default.fileExists(atPath: Self.root.appending(path: "\(package)/Package.resolved").path),
                "\(package) needs a committed Package.resolved: the gate builds from it alone")
        }
        for package in listed {
            let sources = "\(package)/Sources"
            #expect(config.lintPaths?.contains(sources) == true, "swift-format covers \(sources)")
        }
    }
}
