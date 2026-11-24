// swift-tools-version: 6.4
import PackageDescription

// The container runner (roadmap 0024) is a package of its own so that the container library and the packages it brings in
// stay out of the root package's graph (ADR-0001). The root does not depend on it; `vmr check build test` builds and tests
// it (the `packages` key of .vmr.json) and `vmr container-sign` builds and signs the runner.

// BEGIN shared settings (copied verbatim from the root Package.swift; a test compares them)
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

let package = Package(
    name: "Containers",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Release 0.52.1 is the first one that verifies the digest of a pull by digest.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.57.0")
    ],
    targets: [
        // The pure parts of the runner (arguments, kernel archive check, verdict, frame summary, loopback link), free of any
        // container library so their tests run without one.
        .target(name: "ContainerRunnerCore", path: "Sources/ContainerRunnerCore", swiftSettings: hardening),
        .testTarget(
            name: "ContainerRunnerTests", dependencies: ["ContainerRunnerCore"], path: "Tests/ContainerRunnerTests",
            swiftSettings: hardening),

        // The runner itself. Run by the owner, never by the gate (it boots a virtual machine).
        .executableTarget(
            name: "ContainerRunner",
            dependencies: [
                "ContainerRunnerCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
            ],
            path: "Sources/ContainerRunner", swiftSettings: hardening),
    ],
    swiftLanguageModes: [.v6]
)
