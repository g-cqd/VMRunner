import Foundation
import Testing

@testable import VMHelperKit

struct SeatbeltProfileTests {
    private static let helper = "/private/tmp/work/VMHelper"

    private func machine(network: HelperDescriptor.Network = .none) -> HelperDescriptor {
        HelperDescriptor(
            name: "t", boot: .init(kind: .efi, variableStore: "/private/vm/efi.nvram"),
            disks: [.init(path: "/private/vm/disk.img"), .init(path: "/private/vm/data.img", readOnly: true)],
            installerISO: "/private/vm/installer.iso", network: network)
    }

    private func profile(_ descriptor: HelperDescriptor, level: SandboxLevel = .strict, descriptorPath: String? = "/private/vm/d.json")
        throws -> String
    {
        try SeatbeltProfile.generate(
            grants: SandboxGrants(descriptor: descriptor, descriptorPath: descriptorPath, level: level), helperExecutable: Self.helper)
    }

    @Test
    func theProfileDeniesByDefaultBeforeItAllowsAnything() throws {
        let lines = try profile(machine()).split(separator: "\n").filter { !$0.hasPrefix(";;") && !$0.isEmpty }
        #expect(lines.first == "(version 1)")
        #expect(lines.dropFirst().first == "(deny default)")
        #expect(lines.dropFirst(2).first == #"(import "dyld-support.sb")"#)
        #expect(lines.allSatisfy { !$0.hasPrefix("(allow default") })
    }

    @Test
    func eachGrantedFileIsAllowedWithTheAccessItNeedsAndNothingElseOfTheDescriptorIs() throws {
        let text = try profile(machine())
        #expect(text.contains(#"(allow file-read* (literal "/private/vm/installer.iso"))"#))
        #expect(text.contains(#"(allow file-read* (literal "/private/vm/data.img"))"#))
        #expect(text.contains(#"(allow file-read* (literal "/private/vm/d.json"))"#))
        #expect(text.contains(#"(allow file-read* file-write* (literal "/private/vm/disk.img"))"#))
        #expect(text.contains(#"(allow file-read* file-write* (literal "/private/vm/efi.nvram"))"#))
        #expect(!text.contains(#"(allow file-read* file-write* (literal "/private/vm/data.img"))"#), "a read-only disk is never writable")
        #expect(!text.contains(#"(allow file-read* file-write* (literal "/private/vm/installer.iso"))"#))
        #expect(!text.contains("subpath \"/private"), "the descriptor's files are granted one by one, never as a directory")
        #expect(text.contains(#"(extension-class "com.apple.app-sandbox.read-write") (literal "/private/vm/disk.img")"#))
        #expect(!text.contains(#"(extension-class "com.apple.app-sandbox.read-write") (literal "/private/vm/data.img")"#))
    }

    @Test
    func theHelperMayRunAndTheDirectoriesLeadingToGrantsMayBeLookedAt() throws {
        let text = try profile(machine())
        #expect(text.contains("(allow process-exec (literal \"\(Self.helper)\"))"))
        for directory in ["/private", "/private/tmp", "/private/tmp/work", "/private/vm", "/tmp", "/var", "/etc"] {
            #expect(text.contains("(allow file-read-metadata (literal \"\(directory)\"))"), "\(directory)")
        }
        #expect(!text.contains("(allow file-read-metadata (literal \"/private/vm/disk.img\"))"))
    }

    @Test
    func theStrictLevelAndMachinesWithoutAHostedNetworkGetNoSocketRules() throws {
        for (level, network) in [
            (SandboxLevel.strict, HelperDescriptor.Network.fileHandle), (.standard, .none), (.standard, .nat), (.strict, .none),
        ] {
            let text = try profile(machine(network: network), level: level)
            #expect(!text.contains("network-"), "\(level) \(network)")
            #expect(!text.contains("mDNSResponder"), "\(level) \(network)")
        }
    }

    @Test
    func theStandardLevelWithAHostedNetworkMayConnectAndResolveButNotBind() throws {
        let text = try profile(machine(network: .fileHandle), level: .standard)
        #expect(text.contains(#"(allow network-outbound (remote ip "*:*") (literal "/private/var/run/mDNSResponder"))"#))
        #expect(!text.contains("network-bind"))
        #expect(!text.contains("network-inbound"))
    }

    @Test
    func theProfileIsDeterministic() throws {
        #expect(try profile(machine()) == profile(machine()))
    }

    @Test
    func aDescriptorThatArrivesOnStandardInputGrantsNoDescriptorFile() throws {
        let text = try profile(machine(), descriptorPath: nil)
        #expect(!text.contains("d.json"))
    }

    @Test
    func aPathWithParenthesesAndSpacesStaysInsideItsQuotedString() throws {
        var descriptor = machine()
        descriptor.disks = [.init(path: "/private/vm/My Disk (2); (allow default).img")]
        let text = try profile(descriptor)
        #expect(text.contains(#"(allow file-read* file-write* (literal "/private/vm/My Disk (2); (allow default).img"))"#))
        #expect(!text.split(separator: "\n").contains { $0.hasPrefix("(allow default") })
    }

    @Test
    func theGeneratorRefusesAHostilePathEvenWhenTheCallerSkippedValidation() throws {
        let hostile = ["/vm/a\"))(allow default)(literal \"", "/vm/a\nb", "/vm/a\\b", "/vm/../etc", "relative"]
        for path in hostile {
            var descriptor = machine()
            descriptor.disks = [.init(path: path)]
            // Built by hand: `SandboxGrants` takes the descriptor's paths as they are.
            #expect(throws: HelperFailure.self, "\(path.debugDescription)") { try profile(descriptor) }
        }
        #expect(throws: HelperFailure.self) { try profile(machine(), descriptorPath: "/vm/d\n.json") }
        #expect(throws: HelperFailure.self) {
            try SeatbeltProfile.generate(
                grants: SandboxGrants(descriptor: machine(), descriptorPath: nil, level: .strict), helperExecutable: "/bin/\"x")
        }
    }

    @Test
    func aPathGrantedForWritingIsNotListedAgainForReading() throws {
        var descriptor = machine()
        descriptor.disks = [.init(path: "/private/vm/disk.img")]
        let grants = try SandboxGrants(descriptor: descriptor, descriptorPath: "/private/vm/disk.img", level: .strict)
        #expect(!grants.read.contains("/private/vm/disk.img"))
        #expect(grants.readWrite.contains("/private/vm/disk.img"))
    }

    @Test
    func ancestorsListEveryDirectoryAbovePath() {
        #expect(SeatbeltProfile.ancestors(of: "/a/b/c") == ["/a", "/a/b"])
        #expect(SeatbeltProfile.ancestors(of: "/a").isEmpty)
    }
}
