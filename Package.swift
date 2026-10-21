// swift-tools-version: 6.4
import PackageDescription

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
        // Container spike only (ContainerSpike, roadmap 0024, ADR-0017). Release 0.52.1 is the first one that verifies the
        // digest of a pull by digest. The app, `vmr` and every test target link none of it.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.52.1"),
    ],
    targets: [
        .executableTarget(
            name: "VMRunner",
            dependencies: [.product(name: "AsyncAlgorithms", package: "swift-async-algorithms")],
            path: "Sources/VMRunner", swiftSettings: hardening),
        .testTarget(name: "VMRunnerTests", dependencies: ["VMRunner", "TestKit"], path: "Tests/VMRunnerTests", swiftSettings: hardening),

        // The headless helper of the sandbox spike (roadmap 0025): boots one Linux guest from a JSON descriptor, under an
        // engine chosen by `vmr sandbox-spike`. It links the system frameworks and VMHelperKit only, never the app.
        // VMHelperKit holds the descriptor, the events and the Seatbelt profile generator; DevTools links it too, so the
        // launcher and the helper agree on them.
        .target(name: "VMHelperKit", path: "Sources/VMHelperKit", swiftSettings: hardening),
        .executableTarget(name: "VMHelper", dependencies: ["VMHelperKit"], path: "Sources/VMHelper", swiftSettings: hardening),
        .testTarget(name: "VMHelperKitTests", dependencies: ["VMHelperKit"], path: "Tests/VMHelperKitTests", swiftSettings: hardening),

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
                "VMHelperKit",
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

        // Container spike (roadmap 0024): the pure parts of the spike (arguments, kernel archive check, verdict), free of
        // any container library so their tests run without one. Linked by nothing but the spike and its tests.
        .target(name: "ContainerSpikeCore", path: "Sources/ContainerSpikeCore", swiftSettings: hardening),
        .testTarget(
            name: "ContainerSpikeTests", dependencies: ["ContainerSpikeCore"], path: "Tests/ContainerSpikeTests", swiftSettings: hardening),

        // The spike itself: the only target that links the container package. Run by the owner, never by the gate (it boots
        // a virtual machine).
        .executableTarget(
            name: "ContainerSpike",
            dependencies: [
                "ContainerSpikeCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ],
            path: "Sources/ContainerSpike", swiftSettings: hardening),

        // Test support: a stand-in for the arcleak, dolly and deadwood binaries that DevToolsTests packages
        // into a local fixture release. It is never shipped or run by the gate.
        .executableTarget(name: "FakeAnalyzer", path: "Tests/FakeAnalyzer", swiftSettings: hardening),
        .testTarget(
            name: "DevToolsTests",
            dependencies: ["DevTools", "VMHelperKit", "vmr", "FakeAnalyzer"],
            path: "Tests/DevToolsTests",
            swiftSettings: hardening
        ),
    ],
    swiftLanguageModes: [.v6]
)
