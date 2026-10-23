import Testing

@testable import Provisioning

/// The limits a spec is held to. Each limit's boundary is tested with the code that applies it (the reader, the spec's
/// model, the script check).
struct ProvisioningLimitsTests {
    @Test
    func theStandardLimitsAreTheDocumentedOnes() {
        let limits = ProvisioningLimits.standard
        #expect(limits.maxSpecBytes == 65_536)
        #expect(limits.maxSteps == 32)
        #expect(limits.maxFileBytes == 65_536)
        #expect(limits.maxDepth == 8)
    }

    @Test
    func theLargestScriptStillFitsInOneLinuxCommandArgumentOnceEncoded() {
        let encoded = (ProvisioningLimits.standard.maxFileBytes + 2) / 3 * 4
        #expect(encoded + 1_024 < 131_072, "base64 of the largest script, with room for the command around it")
    }

    @Test
    func anErrorNamesItsLineWhenItHasOne() {
        #expect(ProvisioningError(line: 7, "a tab character").description == "line 7: a tab character")
        #expect(ProvisioningError(line: nil, "the spec is empty").description == "the spec is empty")
        #expect(ProvisioningError(line: 7, "x").line == 7)
        #expect(ProvisioningError(line: 7, "x").message == "x")
    }
}
