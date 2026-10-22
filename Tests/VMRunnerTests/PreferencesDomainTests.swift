import Foundation
import Testing

@testable import VMRunner

struct PreferencesDomainTests {
    @Test func aRunWithoutADataDirectoryUsesTheStandardDomain() {
        #expect(PreferencesDomain.suiteName(environment: [:], appIdentifier: "com.example.VMRunner") == nil)
        #expect(PreferencesDomain.suiteName(environment: ["VMRUNNER_DATA_DIR": ""], appIdentifier: "com.example.VMRunner") == nil)
    }

    @Test func aRunWithADataDirectoryGetsADomainOfItsOwn() {
        #expect(
            PreferencesDomain.suiteName(environment: ["VMRUNNER_DATA_DIR": "/tmp/run"], appIdentifier: "com.example.VMRunner")
                == "com.example.VMRunner.data-directory-override")
    }
}
