import Foundation
import Testing

@testable import ContainerRunnerCore

/// The options that say what to run: image, command, size, environment and the event output.
struct RunnerOptionsTests {
    private let current = URL(fileURLWithPath: "/work/dir", isDirectory: true)

    private func parsed(_ options: [String]) throws(RunnerArgumentError) -> RunnerArguments {
        guard case .run(let arguments) = try RunnerArguments.parse(["/tmp/runner"] + options, currentDirectory: current) else {
            throw RunnerArgumentError.missingScratchDirectory
        }
        return arguments
    }

    private func failure(_ options: [String]) -> RunnerArgumentError? {
        do {
            _ = try parsed(options)
            return nil
        } catch {
            return error
        }
    }

    @Test
    func withoutOptionsTheRunIsTheBaseline() throws {
        let arguments = try parsed([])
        #expect(arguments.image == "docker.io/library/alpine:3.24.2")
        #expect(arguments.command.isEmpty)
        #expect(arguments.cpus == 2)
        #expect(arguments.memoryMiB == 512)
        #expect(arguments.environment.isEmpty)
        #expect(!arguments.json)
    }

    @Test
    func everyOptionIsRead() throws {
        let arguments = try parsed([
            "--image", "ghcr.io/example/tool:1", "--command", "/bin/sh", "--command", "-c", "--command", "echo $A", "--cpus", "4",
            "--memory", "2048", "--env", "A=1", "--env", "B_2=two words", "--json", "--network", "loopback",
        ])
        #expect(arguments.image == "ghcr.io/example/tool:1")
        #expect(arguments.command == ["/bin/sh", "-c", "echo $A"], "a value may start with a dash")
        #expect(arguments.cpus == 4)
        #expect(arguments.memoryMiB == 2048)
        #expect(arguments.environment == ["A=1", "B_2=two words"])
        #expect(arguments.json)
        #expect(arguments.network == .loopback)
    }

    @Test
    func theLimitsAreInclusive() throws {
        #expect(try parsed(["--cpus", "1", "--memory", "128"]).cpus == 1)
        #expect(try parsed(["--cpus", "16", "--memory", "16384"]).memoryMiB == 16384)
        #expect(try parsed(["--image", String(repeating: "a", count: 255)]).image.utf8.count == 255)
        #expect(try parsed(["--command", String(repeating: "a", count: 4096)]).command.count == 1)
        #expect(try parsed(Array(repeating: ["--command", ""], count: 64).flatMap { $0 }).command.count == 64)
        let variables = (0..<64).flatMap { ["--env", "V\($0)=x"] }
        #expect(try parsed(variables).environment.count == 64)
        #expect(try parsed(["--env", "EMPTY="]).environment == ["EMPTY="], "an empty value is a value")
        #expect(try parsed(["--env", "A=b=c"]).environment == ["A=b=c"], "only the first = splits")
    }

    @Test
    func aBadImageIsRefused() {
        for image in ["", " ", "alpine latest", "alpine\n", "alpine\t:1", "al\u{7}pine", String(repeating: "a", count: 256)] {
            #expect(failure(["--image", image]) == .invalidImage, "\(image.debugDescription)")
        }
        #expect(failure(["--image"]) == .missingValue(option: "--image"))
    }

    @Test
    func aBadCommandIsRefused() {
        #expect(failure(["--command"]) == .missingValue(option: "--command"))
        #expect(failure(["--command", String(repeating: "a", count: 4097)]) == .invalidCommandArgument(position: 1))
        #expect(failure(["--command", "ok", "--command", "a\u{0}b"]) == .invalidCommandArgument(position: 2))
        #expect(failure(Array(repeating: ["--command", "x"], count: 65).flatMap { $0 }) == .tooManyCommandArguments)
    }

    @Test
    func aBadSizeIsRefused() {
        for value in ["0", "17", "-1", "+2", " 2", "2 ", "two", "", "1.5", "99999999999999999999"] {
            #expect(failure(["--cpus", value]) == .invalidCPUs(value), "\(value.debugDescription)")
        }
        for value in ["127", "16385", "512M", "0x200", "", "-512"] {
            #expect(failure(["--memory", value]) == .invalidMemory(value), "\(value.debugDescription)")
        }
        #expect(failure(["--cpus"]) == .missingValue(option: "--cpus"))
        #expect(failure(["--memory"]) == .missingValue(option: "--memory"))
    }

    @Test
    func aBadEnvironmentEntryIsRefused() {
        #expect(failure(["--env"]) == .missingValue(option: "--env"))
        #expect(failure(["--env", "NOEQUALS"]) == .invalidEnvironment(name: "NOEQUALS"))
        #expect(failure(["--env", "=value"]) == .invalidEnvironment(name: ""))
        #expect(failure(["--env", "1A=x"]) == .invalidEnvironment(name: "1A"))
        #expect(failure(["--env", "A-B=x"]) == .invalidEnvironment(name: "A-B"))
        #expect(failure(["--env", "A B=x"]) == .invalidEnvironment(name: "A B"))
        #expect(failure(["--env", "A=x\ny"]) == .invalidEnvironment(name: "A"))
        #expect(failure(["--env", "A=x\u{0}y"]) == .invalidEnvironment(name: "A"))
        #expect(failure(["--env", "A=1", "--env", "A=2"]) == .duplicateEnvironment(name: "A"))
        #expect(failure(["--env", "a=1", "--env", "A=2"]) == nil, "names are case sensitive")
        #expect(failure((0..<65).flatMap { ["--env", "V\($0)=x"] }) == .tooManyEnvironmentVariables)
    }

    @Test
    func theRefusalsSayWhatIsWrong() {
        let errors: [RunnerArgumentError] = [
            .invalidImage, .tooManyCommandArguments, .invalidCommandArgument(position: 3), .invalidCPUs("0"), .invalidMemory("1"),
            .invalidEnvironment(name: "1A"), .tooManyEnvironmentVariables, .duplicateEnvironment(name: "A"),
        ]
        let texts = errors.map(\.description)
        #expect(Set(texts).count == texts.count)
        #expect(texts[2] == "--command argument 3 is longer than 4096 bytes or contains a NUL")
        #expect(texts[3] == "invalid --cpus '0' (a whole number from 1 to 16)")
        #expect(texts[4] == "invalid --memory '1' (MiB, a whole number from 128 to 16384)")
        #expect(texts[7] == "--env 'A' is given more than once")
    }

    @Test
    func theUsageNamesEveryOption() {
        for option in ["--network", "--image", "--command", "--cpus", "--memory", "--env", "--json"] {
            #expect(RunnerArguments.usage.contains(option), "\(option)")
        }
        #expect(RunnerArguments.usage.contains(RunnerArguments.defaultImage))
    }

    @Test
    func theEnvironmentValueLimitIsInclusive() throws {
        let limit = RunnerArguments.maximumEnvironmentValueBytes
        #expect(limit == 4096)
        #expect(try parsed(["--env", "A=" + String(repeating: "v", count: limit)]).environment.count == 1)
        #expect(failure(["--env", "A=" + String(repeating: "v", count: limit + 1)]) == .invalidEnvironment(name: "A"))
    }

    @Test
    func anEnvironmentEntryReplacesTheImagesOwnOfTheSameName() throws {
        let arguments = try parsed(["--env", "PATH=/opt/bin", "--env", "NEW=1"])
        let base = ["HOME=/root", "PATH=/usr/bin", "PATHX=keep"]
        #expect(arguments.environment(merging: base) == ["HOME=/root", "PATH=/opt/bin", "PATHX=keep", "NEW=1"])
        #expect(try parsed([]).environment(merging: base) == base)
    }
}
