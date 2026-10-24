import Foundation
import Testing

/// The layering of the root package's library targets, as `Package.swift` declares it and as the sources import it:
/// the policy (`NetPolicy`) and the user-mode stack (`NetStack`) know each other and the system frameworks, never the app,
/// so the headless helper can host the stack without linking the app. The manifest is read as text, like
/// `DependencyPolicyTests` does: a nested SwiftPM would wait on the lock the running test holds.
struct ModuleBoundaryTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Frameworks that need a display, a UI toolkit's types or the virtualization entitlement.
    private static let forbiddenImports: Set<String> = ["SwiftUI", "AppKit", "Observation", "Virtualization"]

    private static func manifest() throws -> String {
        try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
    }

    /// The text between the bracket at `start` and its partner, brackets of the same kind nested inside included.
    private static func balanced(in text: String, from start: String.Index, _ open: Character, _ close: Character) -> String? {
        guard text[start] == open else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            if text[index] == open { depth += 1 }
            if text[index] == close {
                depth -= 1
                if depth == 0 { return String(text[text.index(after: start)..<index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The dependencies a target declares: other targets by name, and products (`.product(name:package:)`) by name.
    private static func dependencies(of target: String, in manifest: String) throws -> (targets: Set<String>, products: Set<String>) {
        let declaration = try NSRegularExpression(
            pattern: #"\.(?:target|executableTarget|testTarget)\(\s*name: "\#(target)""#)
        let range = NSRange(manifest.startIndex..., in: manifest)
        let match = try #require(declaration.firstMatch(in: manifest, range: range), "a target named \(target) in Package.swift")
        let open = try #require(manifest.range(of: "(", range: Range(match.range, in: manifest))?.lowerBound)
        let body = try #require(balanced(in: manifest, from: open, "(", ")"), "the arguments of \(target)")
        guard let label = body.range(of: "dependencies:") else { return ([], []) }
        let bracket = try #require(body[label.upperBound...].firstIndex(of: "["), "the dependencies list of \(target)")
        let list = try #require(balanced(in: body, from: bracket, "[", "]"), "the end of the dependencies list of \(target)")

        let products = try NSRegularExpression(pattern: #"\.product\(\s*name: "([^"]+)""#)
        let listRange = NSRange(list.startIndex..., in: list)
        let productNames = products.matches(in: list, range: listRange).compactMap {
            Range($0.range(at: 1), in: list).map { String(list[$0]) }
        }
        let withoutProducts = list.replacingOccurrences(of: #"\.product\([^)]*\)"#, with: "", options: .regularExpression)
        let names = try NSRegularExpression(pattern: #""([^"]+)""#)
        let targetNames = names.matches(in: withoutProducts, range: NSRange(withoutProducts.startIndex..., in: withoutProducts))
            .compactMap { Range($0.range(at: 1), in: withoutProducts).map { String(withoutProducts[$0]) } }
        return (Set(targetNames), Set(productNames))
    }

    /// The first word of each `import` declaration in `source`, access modifiers, attributes and the kind (`import struct X.Y`) removed.
    private static func importedModules(in source: String) -> Set<String> {
        let modifiers: Set<String> = ["public", "package", "internal", "private", "fileprivate"]
        let kinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let"]
        var modules: Set<String> = []
        for line in source.split(separator: "\n") {
            var words = line.split(separator: " ").map(String.init)
            while let first = words.first, first.hasPrefix("@") || modifiers.contains(first) { words.removeFirst() }
            guard words.first == "import", words.count >= 2 else { continue }
            let named = kinds.contains(words[1]) && words.count >= 3 ? words[2] : words[1]
            if let module = named.split(separator: ".").first { modules.insert(String(module)) }
        }
        return modules
    }

    private static func swiftFiles(under directory: String) throws -> [URL] {
        let url = root.appending(path: directory)
        let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil), "\(directory) exists")
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    @Test
    func theNetworkTargetsDependOnEachOtherAndTheSystemFrameworksOnly() throws {
        let manifest = try Self.manifest()
        let policy = try Self.dependencies(of: "NetPolicy", in: manifest)
        #expect(policy.targets.isEmpty, "NetPolicy depends on no other target: \(policy.targets)")
        #expect(policy.products.isEmpty, "NetPolicy depends on no package product: \(policy.products)")
        let stack = try Self.dependencies(of: "NetStack", in: manifest)
        #expect(stack.targets == ["NetPolicy"], "NetStack depends on NetPolicy and nothing else: \(stack.targets)")
        #expect(stack.products.isEmpty, "NetStack depends on no package product: \(stack.products)")
    }

    /// The provisioning library (roadmap 0016) reads text and writes bytes: it needs no other target and no package.
    @Test
    func theGuestSeedTargetDependsOnTheSystemFrameworksOnly() throws {
        let guestSeed = try Self.dependencies(of: "GuestSeed", in: try Self.manifest())
        #expect(guestSeed.targets.isEmpty, "GuestSeed depends on no other target: \(guestSeed.targets)")
        #expect(guestSeed.products.isEmpty, "GuestSeed depends on no package product: \(guestSeed.products)")
    }

    /// The control service's protocol (ADR-0056) links the console library for its socket calls and nothing else.
    @Test
    func theControlLibraryDependsOnTheConsoleLibraryOnly() throws {
        let control = try Self.dependencies(of: "ControlProtocol", in: try Self.manifest())
        #expect(control.targets == ["GuestConsole"], "ControlProtocol links GuestConsole and nothing else: \(control.targets)")
        #expect(control.products.isEmpty, "ControlProtocol depends on no package product: \(control.products)")
    }

    /// The MCP server (roadmap 0005) reaches the service through the control library's client, and reads and writes with the
    /// console's socket calls: nothing else.
    @Test
    func theAgentBridgeDependsOnTheControlAndConsoleLibrariesOnly() throws {
        let bridge = try Self.dependencies(of: "AgentBridge", in: try Self.manifest())
        #expect(bridge.targets == ["ControlProtocol", "GuestConsole"], "AgentBridge links the control and console libraries only")
        #expect(bridge.products.isEmpty, "AgentBridge depends on no package product: \(bridge.products)")
    }

    @Test
    func theHeadlessHelperDoesNotLinkTheApp() throws {
        let manifest = try Self.manifest()
        var seen: Set<String> = []
        var pending = ["VMHelper"]
        while let target = pending.popLast() {
            guard seen.insert(target).inserted else { continue }
            pending += try Self.dependencies(of: target, in: manifest).targets.sorted()
        }
        #expect(!seen.contains("VMRunner"), "VMHelper reaches the app through \(seen.sorted())")
        let direct = try Self.dependencies(of: "VMHelper", in: manifest).targets
        #expect(!direct.contains("VMRunner"), "VMHelper names the app target: \(direct)")
    }

    /// The host-implemented GPU device (roadmap 0014) is a package of its own that the app never links: the root manifest
    /// does not name it, no source of the root package imports it, so `vmr build-app` cannot bundle it, and it depends on
    /// no package.
    @Test
    func theVirtioGPUPackageStaysOutOfTheRootPackageAndTheApp() throws {
        #expect(!(try Self.manifest()).contains("VirtioGPU"), "the root Package.swift names the VirtioGPU package")
        for file in try Self.swiftFiles(under: "Sources") {
            let imported = Self.importedModules(in: try String(contentsOf: file, encoding: .utf8))
            let forbidden = imported.intersection(["VirtioGPURunnerCore", "VirtioGPURunner"])
            #expect(forbidden.isEmpty, "\(file.path) imports \(forbidden.sorted())")
        }
        let nested = try String(contentsOf: Self.root.appending(path: "Packages/VirtioGPU/Package.swift"), encoding: .utf8)
        #expect(!nested.contains(".package("), "the VirtioGPU package depends on no package")
    }

    @Test(arguments: [
        "Sources/NetPolicy", "Sources/NetStack", "Sources/GuestSeed", "Sources/ControlProtocol", "Sources/AgentBridge",
        "Packages/VirtioGPU/Sources/VirtioGPURunnerCore",
    ])
    func noSourceOfTheLibraryTargetsImportsAUserInterfaceOrVirtualizationFramework(directory: String) throws {
        let files = try Self.swiftFiles(under: directory)
        #expect(!files.isEmpty, "\(directory) holds Swift files")
        for file in files {
            let imported = Self.importedModules(in: try String(contentsOf: file, encoding: .utf8))
            let forbidden = imported.intersection(Self.forbiddenImports)
            #expect(forbidden.isEmpty, "\(directory)/\(file.lastPathComponent) imports \(forbidden.sorted())")
        }
    }
}
