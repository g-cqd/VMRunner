// swift-tools-version: 6.4
import PackageDescription

// BEGIN shared settings (Packages/*/Package.swift copy this block verbatim; a test compares them)
// Safety and quality settings shared by every target. Strict memory safety makes each use of an unsafe
// construct visible (`unsafe`), and warnings are errors so the tree stays clean.
let commonSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]
let hardening: [SwiftSetting] = [.strictMemorySafety()] + commonSettings
// END shared settings

// TestKit parks raw `UnsafeContinuation`s by design (a controllable clock, gates and probes), which strict memory
// safety would make every line `unsafe`. It is test support, never linked into the app, so it keeps every other flag.
let testSupportSettings: [SwiftSetting] = commonSettings

let package = Package(
    name: "VMRunner",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Developer tooling only (DevTools and the `vmr` command line). The VMRunner app and its tests link neither.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2", traits: []),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        // Debounces settings writes in the app; also brings in swift-collections.
        .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.1.7"),
        // HeapModule backs TestKit's TestClock sleeper queue.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.3"),
    ],
    targets: [
        .executableTarget(
            name: "VMRunner",
            dependencies: ["NetPolicy", "NetStack", .product(name: "AsyncAlgorithms", package: "swift-async-algorithms")],
            path: "Sources/VMRunner", swiftSettings: hardening),
        .testTarget(
            name: "VMRunnerTests", dependencies: ["VMRunner", "NetPolicy", "NetStack", "TestKit"], path: "Tests/VMRunnerTests",
            swiftSettings: hardening),

        // The network policy (rules, host and IP parsing, the gate): system frameworks only, no app type. The app, the
        // user-mode stack and their tests share it through `package` access; nothing outside this package links it.
        .target(name: "NetPolicy", path: "Sources/NetPolicy", swiftSettings: hardening),
        .testTarget(
            name: "NetPolicyTests", dependencies: ["NetPolicy", "TestKit"], path: "Tests/NetPolicyTests", swiftSettings: hardening),

        // The user-mode network stack (Ethernet, ARP, DHCP, DNS, TCP and UDP flows, the guest VPN detector), judged by NetPolicy.
        // It links system frameworks and NetPolicy only: no Virtualization, no app type, and its logger is injected. Its
        // per-packet path stays inside this module; what the app and the helper call is `package`.
        .target(name: "NetStack", dependencies: ["NetPolicy"], path: "Sources/NetStack", swiftSettings: hardening),
        .testTarget(
            name: "NetStackTests", dependencies: ["NetStack", "NetPolicy", "TestKit"], path: "Tests/NetStackTests",
            swiftSettings: hardening),

        // The headless helper of the sandbox helper (roadmap 0025): boots one Linux guest from a JSON descriptor, under an
        // engine chosen by `vmr sandbox`. It links the system frameworks and VMHelperCore only, never the app.
        // VMHelperCore holds the descriptor, the events and the Seatbelt profile generator; DevTools links it too, so the
        // launcher and the helper agree on them.
        .target(name: "VMHelperCore", path: "Sources/VMHelperCore", swiftSettings: hardening),
        .executableTarget(name: "VMHelper", dependencies: ["VMHelperCore"], path: "Sources/VMHelper", swiftSettings: hardening),
        .testTarget(name: "VMHelperCoreTests", dependencies: ["VMHelperCore"], path: "Tests/VMHelperCoreTests", swiftSettings: hardening),

        // Deterministic and allocation-aware test support, vendored:
        // a controllable Clock, event probes, async gates and a malloc-count guard. Linked by test targets only.
        .target(name: "CTestKitMalloc", path: "Sources/CTestKitMalloc"),
        .target(
            name: "TestKit",
            dependencies: ["CTestKitMalloc", .product(name: "HeapModule", package: "swift-collections")],
            path: "Sources/TestKit",
            swiftSettings: testSupportSettings
        ),
        .testTarget(name: "TestKitTests", dependencies: ["TestKit"], path: "Tests/TestKitTests", swiftSettings: testSupportSettings),

        // Developer tooling, replacing the former shell and Python scripts: `swift run vmr --help`.
        // DevTools holds the logic, `vmr` is the single command-line entry point, the plugins below forward
        // `swift package check | analyzers | build-app` to it.
        .target(
            name: "DevTools",
            dependencies: [
                "VMHelperCore",
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/DevTools",
            swiftSettings: hardening
        ),
        .executableTarget(name: "vmr", dependencies: ["DevTools"], path: "Sources/vmr", swiftSettings: hardening),
        .plugin(
            name: "CheckPlugin",
            capability: .command(
                intent: .custom(verb: "check", description: "Run the quality gate (format, SwiftLint, build, test, analyzers)"),
                permissions: [.writeToPackageDirectory(reason: "The gate builds into .build, .build-* and .build-analyzers")]
            ),
            dependencies: ["vmr"],
            path: "Plugins/CheckPlugin"
        ),
        .plugin(
            name: "AnalyzersPlugin",
            capability: .command(
                intent: .custom(verb: "analyzers", description: "Run the pinned static analyzers (arcleak, dolly, deadwood)"),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Analyzer releases are installed into .tools and baselines are written to the package root"),
                    .allowNetworkConnections(scope: .all(ports: [443]), reason: "Downloads the pinned analyzer releases from GitHub"),
                ]
            ),
            dependencies: ["vmr"],
            path: "Plugins/AnalyzersPlugin"
        ),
        .plugin(
            name: "BuildAppPlugin",
            capability: .command(
                intent: .custom(verb: "build-app", description: "Build, sign and verify build/VMRunner.app"),
                permissions: [.writeToPackageDirectory(reason: "Builds into .build and assembles build/VMRunner.app")]
            ),
            dependencies: ["vmr"],
            path: "Plugins/BuildAppPlugin"
        ),

        // Test support: a stand-in for the arcleak, dolly and deadwood binaries that DevToolsTests packages
        // into a local fixture release. It is never shipped or run by the gate.
        .executableTarget(name: "FakeAnalyzer", path: "Tests/FakeAnalyzer", swiftSettings: hardening),
        .testTarget(
            name: "DevToolsTests",
            dependencies: ["DevTools", "VMHelperCore", "vmr", "FakeAnalyzer"],
            path: "Tests/DevToolsTests",
            swiftSettings: hardening
        ),
    ],
    swiftLanguageModes: [.v6]
)
