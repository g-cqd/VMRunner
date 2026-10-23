import Foundation
import Testing

/// The app's package graph, as `Package.swift` declares it, against what ADR-0001 decides and what the documents
/// that describe it say. The manifest is read as text: a nested SwiftPM would wait on the lock the running test holds.
struct DependencyPolicyTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    private static func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    /// The packages the `VMRunner` executable target's `dependencies:` name, and the targets it names without a package.
    private static func appDependencies() throws -> (packages: Set<String>, targets: Set<String>) {
        let manifest = try text("Package.swift")
        let lists = try matches(#"\.executableTarget\(\s*name: "VMRunner",\s*dependencies: \[([^\]]*)\]"#, in: manifest)
        let list = try #require(lists.first?.first, "the VMRunner executable target and its dependencies list")
        let packages = Set(try matches(#"package: "([^"]+)""#, in: list).flatMap { $0 })
        let withoutProducts = list.replacingOccurrences(of: #"\.product\([^)]*\)"#, with: "", options: .regularExpression)
        return (packages, Set(try matches(#""([^"]+)""#, in: withoutProducts).flatMap { $0 }))
    }

    /// The `swift-…` names in backticks on the first item of ADR-0001's decision.
    private static func adrPackages() throws -> Set<String> {
        let adrs = root.appending(path: "docs/adr")
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: adrs.path).first { $0.hasPrefix("0001-") })
        let adr = try text("docs/adr/\(name)")
        let item = try #require(try matches(#"(?m)^1\. (.*?)^2\. "#, in: adr).first?.first, "item 1 of the decision")
        return Set(try matches(#"`(swift-[a-z-]+)`"#, in: item).flatMap { $0 })
    }

    /// Library targets of this repository the app links besides the packages, none of them outside code: the network policy and
    /// the user-mode stack (ADR-0047), the console, which imports Foundation and the system's C library only (ADR-0052), and
    /// the control service's protocol, which links the console (ADR-0056), and the provisioning library, system frameworks only
    /// (ADR-0012, roadmap 0016). A new one is a decision of its own.
    private static let repositoryLibraries: Set<String> = ["ControlProtocol", "GuestConsole", "GuestSeed", "NetPolicy", "NetStack"]

    @Test
    func theAppTargetDependsOnExactlyThePackagesTheAdrNames() throws {
        let app = try Self.appDependencies()
        #expect(app.packages == (try Self.adrPackages()), "Package.swift and ADR-0001 disagree about what the app links")
        #expect(app.targets == Self.repositoryLibraries, "the app target names only the library targets of this package: \(app.targets)")
        #expect(app.packages.isDisjoint(with: ["swift-subprocess", "swift-argument-parser"]), "tooling packages stay out of the app")
    }

    @Test
    func theConsoleLibraryImportsNothingButFoundationAndSynchronization() throws {
        let directory = Self.root.appending(path: "Sources/GuestConsole")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: directory.appending(path: file), encoding: .utf8)
            for line in source.split(whereSeparator: \.isNewline) where line.hasPrefix("import ") || line.hasPrefix("public import ") {
                let module = line.split(separator: " ").last.map(String.init)
                #expect(["Foundation", "Synchronization"].contains(module), "\(file): \(line) (no Virtualization, no other framework)")
            }
        }
        let manifest = try Self.text("Package.swift")
        let target = try #require(try Self.matches(#"\.target\(name: "GuestConsole"([^)]*)\)"#, in: manifest).first?.first)
        #expect(!target.contains("dependencies"), "GuestConsole depends on no other target or package")
    }

    @Test
    func everyDeclaredPackageIsInTheLicenseNoticeAndTheAppsOnesInTheReadme() throws {
        let manifest = try Self.text("Package.swift")
        let declared = Set(try Self.matches(#"\.package\(url: "[^"]*/([^/"]+?)(?:\.git)?""#, in: manifest).flatMap { $0 })
        #expect(declared.isSuperset(of: try Self.appDependencies().packages))
        let licenses = try Self.text("THIRD_PARTY_LICENSES")
        for package in declared {
            #expect(licenses.contains(package), "THIRD_PARTY_LICENSES does not mention \(package)")
        }
        let readme = try Self.text("README.md")
        for package in try Self.appDependencies().packages {
            #expect(readme.contains(package), "README.md does not mention the app's package \(package)")
        }
    }
}
