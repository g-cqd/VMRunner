import Foundation
import Testing

@testable import DevTools

struct WindowsFirmwareTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theNativeFramebufferHarnessPassesAddressAndUndefinedBehaviourSanitizers() async throws {
        try await withTemporaryDirectory { directory in
            let firmware = Self.root.appending(path: "Firmware/WindowsBoot")
            let binary = directory.appending(path: "firmware-tests")
            let compile = try await ProcessRunner.run(
                CommandSpec(
                    executable: "/usr/bin/clang",
                    arguments: [
                        "-O1", "-g", "-fshort-wchar", "-fno-builtin", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        "-Wall", "-Wextra", "-Werror", "-I", firmware.appending(path: "Include").path,
                        "-I", firmware.appending(path: "Include/AArch64").path,
                        firmware.appending(path: "Tests.c").path, "-o", binary.path,
                    ]))
            #expect(compile.succeeded, "\(compile.standardError)")
            guard compile.succeeded else { return }
            let run = try await ProcessRunner.run(CommandSpec(executable: binary.path))
            #expect(run.succeeded, "\(run.standardError)")
        }
    }

    @Test func vendoredUEFIHeadersMatchTheirPinnedChecksums() throws {
        let folder = Self.root.appending(path: "Firmware/WindowsBoot")
        let manifest = try String(contentsOf: folder.appending(path: "headers.sha256"), encoding: .utf8)
        let lines = manifest.split(separator: "\n")
        #expect(lines.count == 30)
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            #expect(fields.count == 2)
            guard fields.count == 2 else { continue }
            #expect(try FileDigest.sha256(ofFileAt: folder.appending(path: "Include/\(fields[1])")) == fields[0])
        }
    }
}
