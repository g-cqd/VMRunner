import Foundation
import Testing

@testable import VMHelperCore

struct DescriptorTests {
    private static let json = """
        {"version":1,"name":"alpine","cpuCount":2,"memoryMiB":1024,
         "boot":{"kind":"efi","variableStore":"/var/vm/efi.nvram"},
         "disks":[{"path":"/var/vm/disk.img"},{"path":"/var/vm/data.img","readOnly":true}],
         "installerISO":"/var/vm/alpine.iso","network":"nat"}
        """

    private func descriptor(
        boot: HelperDescriptor.Boot = .init(kind: .efi, variableStore: "/vm/efi"),
        disks: [HelperDescriptor.Disk] = [.init(path: "/vm/disk")],
        iso: String? = nil
    ) -> HelperDescriptor {
        HelperDescriptor(name: "t", boot: boot, disks: disks, installerISO: iso)
    }

    @Test
    func aDescriptorIsReadFromJsonAndSortsItsPathsByTheAccessTheyNeed() throws {
        let descriptor = try HelperDescriptor.parse(Data(Self.json.utf8))
        #expect(descriptor.name == "alpine")
        #expect(descriptor.network == .nat)
        #expect(descriptor.readPaths == ["/var/vm/alpine.iso", "/var/vm/data.img"])
        #expect(descriptor.readWritePaths == ["/var/vm/disk.img", "/var/vm/efi.nvram"])
    }

    @Test
    func aMinimalDescriptorTakesTheDefaultsForCpusMemoryDisksAndNetwork() throws {
        let text = #"{"version":1,"name":"m","boot":{"kind":"efi","variableStore":"/vm/efi"},"installerISO":"/vm/a.iso"}"#
        let descriptor = try HelperDescriptor.parse(Data(text.utf8))
        #expect(descriptor.cpuCount == 2 && descriptor.memoryMiB == 1024)
        #expect(descriptor.disks.isEmpty && descriptor.network == .none)
    }

    @Test
    func aKernelBootGrantsTheKernelAndTheInitialRamdiskForReadingOnly() throws {
        let boot = HelperDescriptor.Boot(kind: .kernel, kernel: "/vm/vmlinuz", initrd: "/vm/initrd", commandLine: "console=hvc0")
        let machine = descriptor(boot: boot, disks: [.init(path: "/vm/root.img")])
        try machine.validate()
        #expect(machine.readPaths == ["/vm/initrd", "/vm/vmlinuz"])
        #expect(machine.readWritePaths == ["/vm/root.img"])
    }

    /// A valid descriptor as JSON, with one member replaced by `replacing`.
    private func json(replacing member: String? = nil, with value: String = "") -> String {
        var members = [
            "version": "1", "name": #""x""#, "boot": #"{"kind":"efi","variableStore":"/a"}"#, "cpuCount": "1", "memoryMiB": "1",
            "disks": #"[{"path":"/b"}]"#, "network": #""none""#,
        ]
        if let member { members[member] = value }
        return "{" + members.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}"
    }

    @Test
    func aDescriptorThatIsNotUsableIsRefusedWithTheDescriptorStatus() {
        let bad = [
            json(replacing: "version", with: "2"), json(replacing: "name", with: #""""#), json(replacing: "boot", with: #"{"kind":"efi"}"#),
            json(replacing: "boot", with: #"{"kind":"kernel"}"#),
            json(replacing: "boot", with: #"{"kind":"kernel","kernel":"/k","variableStore":"/v"}"#),
            json(replacing: "boot", with: #"{"kind":"efi","variableStore":"/a","kernel":"/k"}"#), json(replacing: "cpuCount", with: "0"),
            json(replacing: "disks", with: "[]"), json(replacing: "disks", with: #"[{"path":"b"}]"#),
            json(replacing: "network", with: #""bridged""#), "not json",
        ]
        #expect(throws: Never.self) { try HelperDescriptor.parse(Data(json().utf8)) }
        for text in bad {
            do {
                _ = try HelperDescriptor.parse(Data(text.utf8))
                Issue.record("accepted \(text)")
            } catch let failure as HelperFailure {
                #expect(failure.exitStatus == 65, "\(text)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test
    func aPathThatCouldBreakOutOfAProfileOrNameAnotherFileIsRefused() {
        let hostile = [
            "relative/disk.img", "", "/", "//", "/a//b", "/a/./b", "/a/../b", "/a/", "/a\"b", "/a\\b", "/a\nb", "/a\rb", "/a\0b",
            "/a\u{7F}b",
            "/a\"))(allow default)(literal \"", "/" + String(repeating: "a", count: SandboxPath.lengthLimit),
        ]
        for path in hostile {
            #expect(throws: HelperFailure.self, "\(path.debugDescription)") { try SandboxPath.validate(path) }
        }
    }

    @Test
    func parenthesesSemicolonsAndSpacesAreHarmlessInsideTheQuotedPathAndAccepted() throws {
        for path in ["/Volumes/My Disk (2)/a.img", "/tmp/a;b", "/tmp/it's", "/tmp/日本語.img"] {
            try SandboxPath.validate(path)
        }
    }

    @Test
    func canonicalizingResolvesLinksAndKeepsTheRealPrivatePrefix() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vmhelperkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appending(path: "real.img")
        try Data().write(to: real)
        let link = directory.appending(path: "link.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let machine = descriptor(
            boot: .init(kind: .efi, variableStore: directory.appending(path: "new.nvram").path), disks: [.init(path: link.path)])
        let canonical = try machine.canonicalized()
        let root = try #require(SandboxPath.realPath(directory.path))
        #expect(canonical.disks.first?.path == root + "/real.img")
        #expect(canonical.boot.variableStore == root + "/new.nvram", "a file that does not exist yet resolves through its directory")
        #expect(SandboxPath.realPath("/tmp") == "/private/tmp")
    }
}
