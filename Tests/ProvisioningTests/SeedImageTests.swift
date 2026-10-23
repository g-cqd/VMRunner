import Foundation
import Testing

@testable import Provisioning

struct SeedImageTests {
    private func compiledSeed(_ body: String) throws -> CloudInitSeed {
        let spec = try ProvisioningSpec(
            parsing: "apiVersion: vmrunner.dev/v1alpha1\nkind: Provisioning\nmetadata:\n  name: node\nspec:\n" + body)
        let scripts = try ScriptFiles.verify(spec, in: FileManager.default.temporaryDirectory)
        return try SeedCompiler.compile(spec, scripts: scripts, instanceID: "i-1")
    }

    @Test
    func theImageIsLabelledCidataAndHoldsExactlyTheSeedsFiles() throws {
        let seed = try compiledSeed("  cloudInit:\n    userData: |\n      #cloud-config\n")
        let image = SeedImage.bytes(for: seed)
        #expect(Array(image[32_808..<32_814]) == Array("CIDATA".utf8))
        #expect(
            image
                == ISOImage.build(
                    label: "cidata",
                    files: [
                        ISOFile(name: "user-data", contents: Array("#cloud-config\n".utf8)),
                        ISOFile(name: "meta-data", contents: Array("instance-id: i-1\nlocal-hostname: node\n".utf8)),
                    ]))
        #expect(SeedImage.bytes(for: seed) == image, "the same seed gives the same bytes")
    }

    @Test(.enabled(if: SystemTar.isAvailable))
    func fromSpecToImageFileTheFilesReadBackAsCompiled() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let seed = try compiledSeed(
            "  cloudInit:\n    networkData: |\n      version: 2\n  provision:\n  - at: first-boot\n"
                + "    script: |\n      #!/bin/sh\n      echo first\n")
        let url = folder.appending(path: "seed.iso")
        try SeedImage.write(seed, to: url)
        #expect(try SystemTar.names(in: url) == ["meta-data", "network-config", "user-data"])
        #expect(try SystemTar.contents(of: "user-data", in: url) == seed.userData)
        #expect(try SystemTar.contents(of: "meta-data", in: url) == seed.metaData)
        #expect(try SystemTar.contents(of: "network-config", in: url) == "version: 2\n")
    }

    @Test
    func theFileIsReadOnlyAndAnotherWriteReplacesIt() throws {
        let folder = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "seed.iso")
        let first = try compiledSeed("  cloudInit:\n    userData: |\n      #cloud-config\n")
        try SeedImage.write(first, to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o444)
        let second = try compiledSeed("  cloudInit:\n    userData: |\n      #!/bin/sh\n      true\n")
        try SeedImage.write(second, to: url)
        #expect(try [UInt8](Data(contentsOf: url)) == SeedImage.bytes(for: second))
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o444)
    }
}
