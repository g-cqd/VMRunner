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
            dependencies: [
                "ControlProtocol", "GuestConsole", "GuestSeed", "NetPolicy", "NetStack", "VirtioGPU", "VirtioInput",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            path: "Sources/VMRunner", swiftSettings: hardening),
        .testTarget(
            name: "VMRunnerTests",
            dependencies: ["VMRunner", "ControlProtocol", "NetPolicy", "NetStack", "VirtioGPU", "VirtioInput", "TestKit"],
            path: "Tests/VMRunnerTests",
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

        // The pure core of the host-implemented virtio GPU (roadmap 0014, ADR-0058): the wire format, the resource store, the
        // device state, the queue serving and a bounded command record. It imports no framework at all; the app and the runner
        // each bring their own Virtualization adapter and share the library through `package` access.
        .target(name: "VirtioGPU", path: "Sources/VirtioGPU", swiftSettings: hardening),
        .testTarget(name: "VirtioGPUTests", dependencies: ["VirtioGPU"], path: "Tests/VirtioGPUTests", swiftSettings: hardening),

        // The pure core of the host-implemented virtio input device (roadmap 0014, ADR-0058): the wire format, the layouts of its
        // configuration space, the macOS-to-Linux key table, the event encoder, a bounded event queue and the status-queue
        // decoder. It imports no framework at all; the app's adapter links it, through `package` access.
        .target(name: "VirtioInput", path: "Sources/VirtioInput", swiftSettings: hardening),
        .testTarget(name: "VirtioInputTests", dependencies: ["VirtioInput"], path: "Tests/VirtioInputTests", swiftSettings: hardening),

        // The runner's command line (ADR-0042: the testable logic of an executable is `<Executable>Core`), and nothing else.
        .target(name: "VirtioGPURunnerCore", path: "Sources/VirtioGPURunnerCore", swiftSettings: hardening),
        .testTarget(
            name: "VirtioGPURunnerTests", dependencies: ["VirtioGPURunnerCore", "VirtioGPURunner"], path: "Tests/VirtioGPURunnerTests",
            swiftSettings: hardening),

        // The runner boots one Linux guest whose only display is the virtio GPU. The owner runs it, never the gate (it boots a
        // virtual machine); the app does not link it and `vmr build-app` does not build it.
        .executableTarget(
            name: "VirtioGPURunner", dependencies: ["VirtioGPU", "VirtioGPURunnerCore"], path: "Sources/VirtioGPURunner",
            swiftSettings: hardening),

        // The console of a guest (roadmap 0005): a byte bridge between a guest's serial port and a private local socket,
        // and the client that runs commands through it. Foundation and the system's C library only, so the app, the helper
        // and the tooling can all link it.
        .target(name: "GuestConsole", path: "Sources/GuestConsole", swiftSettings: hardening),
        .testTarget(name: "GuestConsoleTests", dependencies: ["GuestConsole"], path: "Tests/GuestConsoleTests", swiftSettings: hardening),

        // GuestSeed (roadmap 0016, ADR-0012): the spec a user writes, its compiler to a cloud-init seed, the host's check of
        // every script file's SHA-256 and the seed's ISO 9660 image. System frameworks only and no other target. The app links
        // it to build a Linux machine's seed at each start; what another target uses is `package`.
        .target(name: "GuestSeed", path: "Sources/GuestSeed", swiftSettings: hardening),
        .testTarget(
            name: "GuestSeedTests", dependencies: ["GuestSeed"], path: "Tests/GuestSeedTests", swiftSettings: hardening),

        // The local control service's protocol (roadmap 0005, ADR-0056): JSON-RPC framing, capability tokens and their checks,
        // and the connection, listener and client over a private local socket. It links GuestConsole for the socket calls,
        // so the private-socket rules have one implementation, and the system frameworks.
        .target(name: "ControlProtocol", dependencies: ["GuestConsole"], path: "Sources/ControlProtocol", swiftSettings: hardening),
        .testTarget(
            name: "ControlProtocolTests", dependencies: ["ControlProtocol", "GuestConsole", "TestKit"],
            path: "Tests/ControlProtocolTests", swiftSettings: hardening),

        // The MCP server over stdio (roadmap 0005): Model Context Protocol messages from an AI agent, each tool call made
        // through the control library's client, so the service's own checks decide. It links ControlProtocol, GuestConsole
        // for the socket calls it reads and writes standard input and output with, and the system frameworks; the app does
        // not link it.
        .target(
            name: "AgentBridge", dependencies: ["ControlProtocol", "GuestConsole"], path: "Sources/AgentBridge",
            swiftSettings: hardening),
        .testTarget(
            name: "AgentBridgeTests", dependencies: ["AgentBridge", "ControlProtocol"], path: "Tests/AgentBridgeTests",
            swiftSettings: hardening),

        // The headless helper of the sandbox helper (roadmap 0025): boots one Linux guest from a JSON descriptor, under an
        // engine chosen by `vmr sandbox`. It links the system frameworks, VMHelperCore and the network library targets
        // (NetStack, NetPolicy, so the helper can host the user-mode stack for a real guest), never the app.
        // VMHelperCore holds the descriptor, the events and the Seatbelt profile generator; DevTools links it too, so the
        // launcher and the helper agree on them.
        .target(name: "VMHelperCore", path: "Sources/VMHelperCore", swiftSettings: hardening),
        .executableTarget(
            name: "VMHelper", dependencies: ["VMHelperCore", "GuestConsole", "NetStack", "NetPolicy"], path: "Sources/VMHelper",
            swiftSettings: hardening),
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
                "GuestConsole",
                "ControlProtocol",
                "AgentBridge",
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
            dependencies: ["DevTools", "VMHelperCore", "GuestConsole", "ControlProtocol", "vmr", "FakeAnalyzer"],
            path: "Tests/DevToolsTests",
            swiftSettings: hardening
        ),
    ],
    swiftLanguageModes: [.v6]
)
