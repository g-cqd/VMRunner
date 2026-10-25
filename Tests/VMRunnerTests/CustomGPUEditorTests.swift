import Foundation
import Testing

@testable import VMRunner

/// What the editor says about the graphics choice, and the help that explains it.
struct CustomGPUEditorTests {
    private func forced(_ values: [String: Any]) -> ManagedPreferences {
        ManagedPreferences(forcedValue: { values[$0] })
    }

    @Test
    func eachChoiceHasItsOwnLabel() {
        #expect(GPUChoice.apple.label == "Apple")
        #expect(GPUChoice.custom.label == "Custom (experimental)")
    }

    @Test
    func aHostBeforeMacOS27SaysSoWhateverTheChoice() {
        for choice in GPUChoice.allCases {
            #expect(choice.note(hostSupports: false, in: forced([:])) == "Needs macOS 27 or later.")
        }
    }

    @Test
    func anOrganisationThatTurnedTheChoiceOffSaysSo() {
        let policy = forced(["AllowCustomGPU": false])
        for choice in GPUChoice.allCases {
            #expect(choice.note(hostSupports: true, in: policy) == "Your organisation turned the custom GPU off.")
        }
    }

    @Test
    func anOpenChoiceSaysWhatItMeans() {
        let policy = forced([:])
        #expect(GPUChoice.apple.note(hostSupports: true, in: policy).hasPrefix("Apple's graphics device."))
        let custom = GPUChoice.custom.note(hostSupports: true, in: policy)
        #expect(custom.contains("two dimensions") && custom.contains("suspended"))
    }

    @Test
    func theHelpNamesTheHostVersionTheManagedKeyAndTheLossOfSuspend() {
        let entry = HelpTopic.customGPU.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        #expect(entry.area == .display)
        #expect(text.contains("macOS 27"))
        #expect(text.contains("AllowCustomGPU"))
        #expect(text.contains("suspend"))
        #expect(text.contains("Isolated and Hardened"))
        #expect(entry.related.contains(.exposureSummary))
    }

    @Test
    func theTopicsThatTalkAboutGraphicsPointToIt() {
        #expect(HelpTopic.graphics.entry.related.contains(.customGPU))
        #expect(HelpTopic.linuxBootText.entry.related.contains(.customGPU))
        #expect(HelpTopic.devices.entry.related.contains(.customGPU))
    }

    @Test
    func theGraphicsTopicNoLongerCallsTheCustomDeviceAResearchDirection() {
        let entry = HelpTopic.graphics.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        #expect(!text.contains("research direction"))
        #expect(text.contains("Custom GPU"))
        #expect(text.contains("not 3D acceleration"))
    }

    @Test
    func theBootTextTopicStillSaysThereIsNoAcceleration() {
        let entry = HelpTopic.linuxBootText.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        #expect(text.contains("no acceleration") && text.contains("no 3D acceleration"))
        #expect(text.contains("custom GPU"))
    }
}
