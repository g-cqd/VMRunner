import Foundation
import Testing

@testable import VMRunner

/// What stored configurations hold for the installation media: the coding of `ImageSource` and `Checksum` is a file format.
struct ImageSourceCodingTests {
    private func config(source: String) throws -> VMConfig {
        let json = #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"old","guest":"linux","source":"# + source + "}"
        return try VMConfig.decode(from: Data(json.utf8))
    }

    @Test(arguments: [("sha256", Checksum.Algorithm.sha256), ("sha1", .refused("sha1")), ("md5", .refused("md5"))])
    func anOldConfigNamingAnImageAndItsChecksumStillDecodes(name: String, algorithm: Checksum.Algorithm) throws {
        let stored =
            #"{"remote":{"_0":"https://example.com/a.iso","checksum":{"algorithm":"\#(name)","value":"ab12"}}}"#
        let decoded = try config(source: stored)
        let url = try #require(URL(string: "https://example.com/a.iso"))
        #expect(decoded.source == .remote(url, checksum: Checksum(algorithm: algorithm, value: "ab12")))
    }

    @Test func theOtherSourcesStillDecode() throws {
        let url = try #require(URL(string: "https://example.com/a.iso"))
        #expect(try config(source: #"{"remote":{"_0":"https://example.com/a.iso"}}"#).source == .remote(url, checksum: nil))
        #expect(try config(source: #"{"latestMac":{}}"#).source == .latestMac)
        #expect(try config(source: #"{"linuxCatalog":{"id":"debian"}}"#).source == .linuxCatalog(id: "debian"))
        #expect(try config(source: #"{"local":{"_0":"/tmp/a.iso"}}"#).source == .local("/tmp/a.iso"))
    }

    @Test func writingKeepsTheStoredShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let url = try #require(URL(string: "https://example.com/a.iso"))
        let source = ImageSource.remote(url, checksum: Checksum(algorithm: .refused("sha1"), value: "ab12"))
        #expect(
            String(bytes: try encoder.encode(source), encoding: .utf8)
                == #"{"remote":{"_0":"https://example.com/a.iso","checksum":{"algorithm":"sha1","value":"ab12"}}}"#)
    }

    @Test func aRefusedAlgorithmIsWrittenBackAsItWasStored() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stored = #"{"algorithm":"md5","value":"ab12"}"#
        let decoded = try JSONDecoder().decode(Checksum.self, from: Data(stored.utf8))
        #expect(decoded.algorithm == .refused("md5"))
        #expect(String(bytes: try encoder.encode(decoded), encoding: .utf8) == stored)
    }
}
