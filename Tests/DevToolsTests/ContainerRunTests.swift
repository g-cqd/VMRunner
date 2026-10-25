import ArgumentParser
import Foundation
import Testing

@testable import DevTools

/// `vmr container-run`: the plan that checks the options and builds the runner's command line, and the refusal without
/// `--boot`. Nothing here builds the runner's package or starts it, so no virtual machine starts.
struct ContainerRunTests {
    private let surroundings = ContainerRunPlan.Surroundings(
        workingDirectory: URL(fileURLWithPath: "/work/dir", isDirectory: true),
        temporaryDirectory: URL(fileURLWithPath: "/private/tmp/t", isDirectory: true),
        token: "0123abcd",
        home: URL(fileURLWithPath: "/Users/someone", isDirectory: true))

    private func plan(_ change: (inout ContainerRunPlan.Options) -> Void = { _ in }) throws -> ContainerRunPlan {
        var options = ContainerRunPlan.Options()
        options.confirmed = true
        change(&options)
        return try ContainerRunPlan.make(options, in: surroundings)
    }

    private func refusal(_ change: (inout ContainerRunPlan.Options) -> Void) -> String? {
        do {
            _ = try plan(change)
            return nil
        } catch let error as ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test
    func withoutTheConfirmationNothingRuns() throws {
        let error = #expect(throws: ToolError.self) { try ContainerRunPlan.make(.init(), in: surroundings) }
        #expect(error?.status == ToolError.usageStatus)
        #expect(error?.message.contains("boots a real virtual machine") == true)
        #expect(error?.message.contains("Pass --boot") == true)
        #expect(error?.message.contains("Real-guest runs") == true)
    }

    @Test
    func defaultsAreLeftOutAndTheScratchIsFreshUnderTheTemporaryDirectory() throws {
        let plan = try plan()
        #expect(plan.isFresh)
        #expect(plan.scratch.path == "/private/tmp/t/vmr-container-run-0123abcd")
        #expect(plan.runnerArguments == ["/private/tmp/t/vmr-container-run-0123abcd"])
    }

    @Test
    func theArgumentsFollowTheRunnersOrderWhateverTheOrderOfTheOptions() throws {
        let plan = try plan {
            $0.json = true
            $0.network = .loopback
            $0.environment = ["A=1", "B=two words"]
            $0.memoryMiB = 1_024
            $0.cpus = 1
            $0.command = ["/bin/sh", "-c", "echo $A"]
            $0.image = "ghcr.io/example/tool:1"
            $0.scratch = "/private/tmp/keep"
        }
        #expect(!plan.isFresh)
        #expect(
            plan.runnerArguments == [
                "/private/tmp/keep", "--image", "ghcr.io/example/tool:1", "--command", "/bin/sh", "--command", "-c", "--command", "echo $A",
                "--cpus", "1", "--memory", "1024", "--env", "A=1", "--env", "B=two words", "--network", "loopback", "--json",
            ])
    }

    @Test
    func aGivenScratchDirectoryIsReusedAndARelativeOneIsTakenFromTheWorkingDirectory() throws {
        #expect(try plan { $0.scratch = "cache" }.scratch.path == "/work/dir/cache")
        #expect(try plan { $0.scratch = "/private/tmp/a/../keep" }.scratch.path == "/private/tmp/keep")
    }

    @Test
    func aScratchDirectoryInTheLibraryTheHomeFolderOrTheRootIsRefused() {
        for path in ["/Users/someone/Library/Application Support/VMRunner", "/Users/someone", "/"] {
            #expect(refusal { $0.scratch = path } != nil, "\(path)")
        }
        #expect(refusal { $0.scratch = "" } != nil)
    }

    @Test
    func theCapsOfARealGuestRunAreInclusive() throws {
        #expect(
            try plan {
                $0.cpus = 2
                $0.memoryMiB = 2_048
            }.runnerArguments.contains("2048"))
        #expect(
            try plan {
                $0.cpus = 1
                $0.memoryMiB = 128
            }.runnerArguments.contains("128"))
        #expect(try plan { $0.maximumSeconds = 3_600 }.options.maximumSeconds == 3_600)
        #expect(refusal { $0.cpus = 3 }?.contains("--cpus must be from 1 to 2") == true)
        #expect(refusal { $0.cpus = 0 } != nil)
        #expect(refusal { $0.memoryMiB = 2_049 }?.contains("--memory must be from 128 to 2048") == true)
        #expect(refusal { $0.memoryMiB = 127 } != nil)
        #expect(refusal { $0.maximumSeconds = 0 }?.contains("--max-seconds") == true)
        #expect(refusal { $0.maximumSeconds = 3_601 } != nil)
    }

    @Test
    func aCommandArgumentMayStartWithADash() throws {
        let command = try ContainerRunCommand.parse(["--boot", "--command", "/bin/sh", "--command", "-c", "--command", "echo hi"])
        #expect(command.command == ["/bin/sh", "-c", "echo hi"])
    }

    @Test
    func theCommandIsRegisteredAndRefusesWithoutBootBeforeBuildingAnything() async throws {
        try await withTemporaryDirectory { directory in
            let run = try await VMR.vmr(["container-run", "--root", directory.path, "--command", "true"], in: directory)
            #expect(run.status == ToolError.usageStatus, "\(run.combined)")
            #expect(run.error.contains("Pass --boot"), "\(run.error)")
            #expect(run.output.isEmpty, "\(run.output)")
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: ".build").path))
        }
    }
}
