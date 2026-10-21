// swift-tools-version: 6.4
import PackageDescription

// Safety and quality settings shared by every target. Strict memory safety makes each use of an unsafe
// construct visible (`unsafe`), and warnings are errors so the tree stays clean.
let hardening: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "VMRunner",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Developer tooling only (DevTools and the `vmr` command line). The VMRunner app and its tests link neither.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2", traits: []),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .executableTarget(name: "VMRunner", path: "Sources/VMRunner", swiftSettings: hardening),
        .testTarget(name: "VMRunnerTests", dependencies: ["VMRunner"], path: "Tests/VMRunnerTests", swiftSettings: hardening),

        // Developer tooling, replacing the former shell and Python scripts: `swift run vmr --help`.
        // DevTools holds the logic, `vmr` is the single command-line entry point, the plugins below forward
        // `swift package check | analyzers | build-app` to it.
        .target(
            name: "DevTools",
            dependencies: [
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
            dependencies: ["DevTools", "vmr", "FakeAnalyzer"],
            path: "Tests/DevToolsTests",
            swiftSettings: hardening
        ),
    ],
    swiftLanguageModes: [.v6]
)
