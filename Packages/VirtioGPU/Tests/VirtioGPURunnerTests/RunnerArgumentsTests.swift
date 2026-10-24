import Testing

@testable import VirtioGPURunnerCore

struct RunnerArgumentsTests {
    private let home = "/Users/someone"

    private func failure(_ arguments: [String]) -> RunnerArgumentError? {
        do {
            _ = try RunnerArguments.parse(arguments, home: home)
            return nil
        } catch {
            return error
        }
    }

    private func options(_ arguments: [String]) throws -> RunnerOptions {
        guard case .run(let options) = try RunnerArguments.parse(arguments, home: home) else {
            Issue.record("not a run: \(arguments)")
            return RunnerOptions(directory: "", disk: "")
        }
        return options
    }

    @Test
    func aRunNeedsADirectoryAndADiskAndTakesTheCapsAsDefaults() throws {
        let parsed = try options(["--directory", "/tmp/gpu-run/", "--disk", "/tmp/dl/disk.raw"])
        #expect(parsed == RunnerOptions(directory: "/tmp/gpu-run", disk: "/tmp/dl/disk.raw"))
        #expect([parsed.cpuCount, parsed.memoryMiB, parsed.maxSeconds] == [2, 2048, 900])
        #expect(parsed.seed == nil && !parsed.dryRun)
        #expect(parsed.variableStorePath == "/tmp/gpu-run/efi-vars.fd")
        #expect(parsed.consoleLogPath == "/tmp/gpu-run/console.log")
        #expect(parsed.pidPath == "/tmp/gpu-run/runner.pid")
    }

    @Test
    func everyOptionIsRead() throws {
        let parsed = try options([
            "--dry-run", "--seed", "/tmp/s/seed.iso", "--cpus", "1", "--memory-mib", "1024", "--max-seconds", "60",
            "--directory", "/tmp/r", "--disk", "/tmp/d.raw",
        ])
        #expect(parsed.seed == "/tmp/s/seed.iso")
        #expect([parsed.cpuCount, parsed.memoryMiB, parsed.maxSeconds] == [1, 1024, 60])
        #expect(parsed.dryRun)
    }

    @Test
    func helpAndDescribeNeedNothingElse() throws {
        #expect(try RunnerArguments.parse(["--help"], home: home) == .help)
        #expect(try RunnerArguments.parse(["-h", "--bogus"], home: home) == .help)
        #expect(try RunnerArguments.parse(["--describe"], home: home) == .describe)
    }

    @Test(arguments: [
        (["--directory", "/tmp/r"], RunnerArgumentError.missing(option: "--disk")),
        (["--disk", "/tmp/d"], .missing(option: "--directory")),
        ([], .missing(option: "--directory")),
        (["--directory"], .missingValue(option: "--directory")),
        (["--window"], .unknownOption("--window")),
        (["--directory", "/tmp/r", "--disk", "/tmp/d", "--cpus", "3"], .outOfRange(option: "--cpus", value: 3, allowed: 1...2)),
        (["--directory", "/tmp/r", "--disk", "/tmp/d", "--cpus", "0"], .outOfRange(option: "--cpus", value: 0, allowed: 1...2)),
        (
            ["--directory", "/tmp/r", "--disk", "/tmp/d", "--memory-mib", "4096"],
            .outOfRange(option: "--memory-mib", value: 4096, allowed: 1024...2048)
        ),
        (
            ["--directory", "/tmp/r", "--disk", "/tmp/d", "--max-seconds", "3601"],
            .outOfRange(option: "--max-seconds", value: 3601, allowed: 10...3600)
        ),
        (["--directory", "/tmp/r", "--disk", "/tmp/d", "--cpus", "two"], .notANumber(option: "--cpus", value: "two")),
        (["--directory", "tmp/r", "--disk", "/tmp/d"], .notAbsolute(option: "--directory", path: "tmp/r")),
        (["--directory", "/tmp/../Users/someone", "--disk", "/tmp/d"], .notAbsolute(option: "--directory", path: "/tmp/../Users/someone")),
        (["--directory", "/tmp/r", "--disk", "/tmp/./d"], .notAbsolute(option: "--disk", path: "/tmp/./d")),
        (["--directory", "/tmp/r", "--disk", "/tmp/d", "--seed", "seed.iso"], .notAbsolute(option: "--seed", path: "seed.iso")),
    ])
    func aBadCommandLineIsRefused(arguments: [String], expected: RunnerArgumentError) {
        #expect(failure(arguments) == expected)
    }

    @Test(arguments: ["/", "//", "/Users/someone", "/Users/someone/", "/Users/someone/Library", "/Users/someone/Library/VMRunner"])
    func theRootTheHomeFolderAndTheLibraryAreRefused(directory: String) {
        guard case .refusedDirectory = failure(["--directory", directory, "--disk", "/tmp/d"]) else {
            Issue.record("\(directory) was accepted")
            return
        }
    }

    @Test
    func aFolderBesideTheLibraryIsAccepted() throws {
        #expect(try options(["--directory", "/Users/someone/LibraryCopy", "--disk", "/tmp/d"]).directory == "/Users/someone/LibraryCopy")
    }

    @Test
    func everyErrorSaysWhatWasWrong() {
        #expect(RunnerArgumentError.missing(option: "--disk").description == "--disk is required")
        #expect(RunnerArgumentError.unknownOption("-x").description == "unknown option '-x'")
        #expect(RunnerArgumentError.outOfRange(option: "--cpus", value: 3, allowed: 1...2).description == "--cpus 3 is outside 1...2")
        #expect(RunnerArguments.usage.contains("--max-seconds"))
    }
}
