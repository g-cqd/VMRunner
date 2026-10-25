import Foundation

/// A package with the layout `vmr build-app` expects: an executable product named VMRunner, `Resources/Info.plist`
/// and the three entitlement files (the app's two and the container runner's). It needs no SwiftUI and is never launched.
/// The container runner is not built from the fixture: tests hand `build-app` a copy of a system executable (``runner(in:)``).
enum AppFixture {
    static let defaultEntitlements = entitlements(["com.apple.security.virtualization": "<true/>"])

    static let runnerEntitlements = entitlements(["com.apple.security.virtualization": "<true/>"])

    static let hardenedEntitlements = entitlements([
        "com.apple.security.virtualization": "<true/>",
        "com.apple.security.hardened-process": "<true/>",
        "com.apple.security.hardened-process.platform-restrictions-string": "<string>2</string>",
    ])

    static func entitlements(_ entries: [String: String]) -> String {
        let body = entries.sorted { $0.key < $1.key }.map { "    <key>\($0.key)</key>\n    \($0.value)" }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \(body)
            </dict>
            </plist>
            """
    }

    /// A copy of a system executable in `directory`, to stand in for the container runner's build.
    static func runner(in directory: URL) throws -> URL {
        let runner = directory.appending(path: "runner-fixture")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: runner)
        return runner
    }

    static func files(
        defaultEntitlements: String = defaultEntitlements,
        hardenedEntitlements: String = hardenedEntitlements,
        runnerEntitlements: String = runnerEntitlements
    ) -> [String: String] {
        [
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
              name: "Fixture",
              platforms: [.macOS(.v14)],
              targets: [.executableTarget(name: "VMRunner")]
            )
            """,
            "Sources/VMRunner/main.swift": "import Foundation\nFileHandle.standardOutput.write(Data(\"hello\\n\".utf8))\n",
            "Resources/Info.plist": """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key><string>dev.example.Fixture</string>
                <key>CFBundleName</key><string>VMRunner</string>
                <key>CFBundleExecutable</key><string>VMRunner</string>
                <key>CFBundlePackageType</key><string>APPL</string>
                <key>CFBundleVersion</key><string>1</string>
            </dict>
            </plist>
            """,
            "Resources/VMRunner.entitlements": defaultEntitlements,
            "Resources/VMRunner.hardened.entitlements": hardenedEntitlements,
            "Resources/ContainerRunner.entitlements": runnerEntitlements,
        ]
    }
}
