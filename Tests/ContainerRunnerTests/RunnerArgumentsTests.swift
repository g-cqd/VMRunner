import Foundation
import Testing

@testable import ContainerRunnerCore

struct RunnerArgumentsTests {
    private let current = URL(fileURLWithPath: "/work/dir", isDirectory: true)

    private func failure(_ arguments: [String]) -> RunnerArgumentError? {
        do {
            _ = try RunnerArguments.parse(arguments, currentDirectory: current)
            return nil
        } catch {
            return error
        }
    }

    private func scratch(_ arguments: [String]) throws -> String? {
        guard case .run(let parsed) = try RunnerArguments.parse(arguments, currentDirectory: current) else { return nil }
        return parsed.scratch.path
    }

    @Test
    func anAbsoluteScratchDirectoryIsKept() throws {
        #expect(try scratch(["/tmp/runner"]) == "/tmp/runner")
    }

    @Test
    func aRelativeScratchDirectoryIsTakenFromTheCurrentDirectoryAndStandardized() throws {
        #expect(try scratch(["out/../scratch"]) == "/work/dir/scratch")
    }

    private func network(_ arguments: [String]) throws -> RunnerArguments.Network? {
        guard case .run(let parsed) = try RunnerArguments.parse(arguments, currentDirectory: current) else { return nil }
        return parsed.network
    }

    @Test
    func theNetworkIsNoneUnlessAskedForByName() throws {
        #expect(try network(["/tmp/runner"]) == RunnerArguments.Network.none)
        #expect(try network(["--network", "loopback", "/tmp/runner"]) == .loopback)
        #expect(try network(["/tmp/runner", "--network", "none"]) == RunnerArguments.Network.none)
    }

    @Test
    func helpWinsOverEverythingElse() throws {
        #expect(try RunnerArguments.parse(["/tmp/runner", "-h"], currentDirectory: current) == .help)
        #expect(try RunnerArguments.parse(["--help"], currentDirectory: current) == .help)
    }

    @Test
    func badCommandLinesAreNamed() {
        #expect(failure([]) == .missingScratchDirectory)
        #expect(failure([""]) == .missingScratchDirectory)
        #expect(failure(["/a", "/b"]) == .extraArgument("/b"))
        #expect(failure(["/a", "--bridge"]) == .unknownOption("--bridge"))
        #expect(failure(["--network", "loopback"]) == .missingScratchDirectory)
        #expect(failure(["/a", "--network"]) == .missingValue(option: "--network"))
        #expect(failure(["/a", "--network", "nat"]) == .unknownNetwork("nat"))
    }

    @Test
    func everyFileLivesUnderTheScratchDirectory() {
        let layout = RunnerLayout(scratch: URL(fileURLWithPath: "/tmp/runner", isDirectory: true))
        for url in [layout.kernelArchive, layout.kernelStaging, layout.kernelImage, layout.imageStore] {
            #expect(url.path.hasPrefix("/tmp/runner/"), "\(url.path)")
        }
        #expect(layout.kernelArchive.lastPathComponent == KernelArchive.fileName)
    }
}
