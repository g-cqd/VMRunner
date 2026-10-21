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
    targets: [
        .executableTarget(name: "VMRunner", path: "Sources/VMRunner", swiftSettings: hardening),
        .testTarget(name: "VMRunnerTests", dependencies: ["VMRunner"], path: "Tests/VMRunnerTests", swiftSettings: hardening),
    ],
    swiftLanguageModes: [.v6]
)
