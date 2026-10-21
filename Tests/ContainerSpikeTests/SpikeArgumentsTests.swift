import Foundation
import Testing

@testable import ContainerSpikeCore

struct SpikeArgumentsTests {
    private let current = URL(fileURLWithPath: "/work/dir", isDirectory: true)

    private func failure(_ arguments: [String]) -> SpikeArgumentError? {
        do {
            _ = try SpikeArguments.parse(arguments, currentDirectory: current)
            return nil
        } catch {
            return error
        }
    }

    private func scratch(_ arguments: [String]) throws -> String? {
        guard case .run(let parsed) = try SpikeArguments.parse(arguments, currentDirectory: current) else { return nil }
        return parsed.scratch.path
    }

    @Test
    func anAbsoluteScratchDirectoryIsKept() throws {
        #expect(try scratch(["/tmp/spike"]) == "/tmp/spike")
    }

    @Test
    func aRelativeScratchDirectoryIsTakenFromTheCurrentDirectoryAndStandardized() throws {
        #expect(try scratch(["out/../scratch"]) == "/work/dir/scratch")
    }

    @Test
    func helpWinsOverEverythingElse() throws {
        #expect(try SpikeArguments.parse(["/tmp/spike", "-h"], currentDirectory: current) == .help)
        #expect(try SpikeArguments.parse(["--help"], currentDirectory: current) == .help)
    }

    @Test
    func badCommandLinesAreNamed() {
        #expect(failure([]) == .missingScratchDirectory)
        #expect(failure([""]) == .missingScratchDirectory)
        #expect(failure(["/a", "/b"]) == .extraArgument("/b"))
        #expect(failure(["/a", "--bridge"]) == .unknownOption("--bridge"))
    }

    @Test
    func everyFileLivesUnderTheScratchDirectory() {
        let layout = SpikeLayout(scratch: URL(fileURLWithPath: "/tmp/spike", isDirectory: true))
        for url in [layout.kernelArchive, layout.kernelStaging, layout.kernelImage, layout.imageStore] {
            #expect(url.path.hasPrefix("/tmp/spike/"), "\(url.path)")
        }
        #expect(layout.kernelArchive.lastPathComponent == KernelArchive.fileName)
    }
}
