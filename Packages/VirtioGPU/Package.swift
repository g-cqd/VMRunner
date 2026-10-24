// swift-tools-version: 6.4
import PackageDescription

// A virtio-gpu device implemented by the host (roadmap 0014, ADR-0014): a feasibility study of a two-dimensional scanout for
// Linux guests through the framework's custom virtio devices, which need macOS 27. A package of its own so that nothing of it
// reaches the root package's graph or the app: the root does not depend on it, `vmr build-app` never builds it, and
// `vmr check build test` builds and tests it (the `packages` key of .vmr.json).

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
    name: "VirtioGPU",
    platforms: [.macOS(.v26)],
    targets: [
        // The pure parts: the device's identity and configuration space, free of the virtualization framework so their tests
        // run anywhere.
        .target(name: "VirtioGPURunnerCore", path: "Sources/VirtioGPURunnerCore", swiftSettings: hardening),
        .testTarget(
            name: "VirtioGPURunnerTests", dependencies: ["VirtioGPURunnerCore"], path: "Tests/VirtioGPURunnerTests",
            swiftSettings: hardening),

        // The runner itself. Run by the owner, never by the gate (it boots a virtual machine).
        .executableTarget(
            name: "VirtioGPURunner", dependencies: ["VirtioGPURunnerCore"], path: "Sources/VirtioGPURunner",
            swiftSettings: hardening),
    ],
    swiftLanguageModes: [.v6]
)
