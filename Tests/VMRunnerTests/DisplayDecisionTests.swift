import Foundation
import Testing

@testable import VMRunner

/// The rule behind a start size is logged, and no stored configuration gets a cold start past the cap.
struct DisplayDecisionTests {
    private let retinaWindow = CGSize(width: 1512, height: 900)

    private func linux(_ change: (inout VMConfig) -> Void = { _ in }) -> VMConfig {
        var config = VMConfig.new(name: "l", guest: .linux)
        change(&config)
        return config
    }

    @Test func aWindowWiderThanTheCapIsReducedAndTheRuleSaysSo() {
        let decision = StartDisplay.decide(for: linux { $0.pixelsPerPoint = 2 }, window: retinaWindow, restoring: false)
        #expect(decision.width == 1280 && decision.height == 760)
        #expect(decision.source == .window && decision.cap == .reduced && !decision.rememberedSizeIgnored)
        #expect(decision.rule == "source window, width cap applied, remembered size none")
    }

    @Test func aWindowWithinTheCapIsLeftAloneAndTheRuleSaysSo() {
        let decision = StartDisplay.decide(for: linux(), window: CGSize(width: 1000, height: 600), restoring: false)
        #expect(decision.width == 1000 && decision.cap == .withinCap)
    }

    @Test func aColdStartSaysThatItIgnoredTheRememberedSize() {
        let config = linux {
            $0.lastDisplayWidth = 3456
            $0.lastDisplayHeight = 2234
        }
        let decision = StartDisplay.decide(for: config, window: retinaWindow, restoring: false)
        #expect(decision.width == 1280 && decision.rememberedSizeIgnored)
        #expect(decision.rule.hasSuffix("remembered size ignored"))
    }

    @Test func aSavedStateSaysThatItUsedTheRememberedSizeUncapped() {
        let config = linux {
            $0.lastDisplayWidth = 3456
            $0.lastDisplayHeight = 2234
        }
        let decision = StartDisplay.decide(for: config, window: retinaWindow, restoring: true)
        #expect(decision.size == (3456, 2234) && decision.source == .savedState && decision.cap == .notApplicable)
        #expect(decision.rule == "source saved state, width cap does not apply, remembered size used")
    }

    @Test func aFixedPresetAndAConfiguredSizeWithoutAWindowNameThemselves() {
        let preset = linux {
            $0.fitsWindowAtStart = false
            $0.displayWidth = 2560
            $0.displayHeight = 1600
        }
        let fixed = StartDisplay.decide(for: preset, window: retinaWindow, restoring: false)
        #expect(fixed.source == .fixedSize && fixed.cap == .reduced && fixed.size == (1280, 800))
        #expect(StartDisplay.decide(for: linux(), window: nil, restoring: false).source == .configuredSizeWithoutWindow)
    }

    @Test func aFixedSizeThatTheGuestKeepsIsNotCapped() {
        let config = linux {
            $0.fitsWindowAtStart = false
            $0.automaticallyReconfiguresDisplay = false
            $0.displayWidth = 2560
            $0.displayHeight = 1600
        }
        let decision = StartDisplay.decide(for: config, window: retinaWindow, restoring: false)
        #expect(decision.width == 2560 && decision.cap == .notApplicable)
    }

    @Test func macOSIsNeverCapped() {
        let decision = StartDisplay.decide(for: VMConfig.new(name: "m", guest: .macOS), window: retinaWindow, restoring: false)
        #expect(decision.cap == .notApplicable)
    }

    /// Every combination an existing Linux machine can have stored, started cold: the firmware never gets a framebuffer
    /// wider than the cap, except for the one fixed size the user asked the guest to keep for the whole run.
    @Test func noStoredLinuxConfigurationStartsColdAboveTheCap() {
        let windows: [CGSize?] = [
            nil, CGSize(width: 100, height: 100), CGSize(width: 1000, height: 600), retinaWindow, CGSize(width: 3456, height: 2000),
        ]
        let sizes = [(1280, 800), (1920, 1200), (2560, 1600), (3456, 2234), (7680, 4320)]
        let remembered: [(Int, Int)?] = [nil, (3456, 2234), (3200, 2000)]
        var checked = 0
        for window in windows {
            for (width, height) in sizes {
                for (fits, follows) in [(true, true), (true, false), (false, true), (false, false)] {
                    for pixelsPerPoint in [1, 2, 3] {
                        for last in remembered {
                            let config = linux {
                                $0.displayWidth = width
                                $0.displayHeight = height
                                $0.fitsWindowAtStart = fits
                                $0.automaticallyReconfiguresDisplay = follows
                                $0.pixelsPerPoint = pixelsPerPoint
                                $0.lastDisplayWidth = last?.0
                                $0.lastDisplayHeight = last?.1
                            }
                            let start = StartDisplay.size(for: config, window: window, restoring: false)
                            checked += 1
                            let stored = last.debugDescription
                            #expect(
                                start.width <= StartDisplay.legibleWidth || (!fits && !follows),
                                "\(width)x\(height) fits \(fits) follows \(follows) \(pixelsPerPoint)x last \(stored): \(start)")
                        }
                    }
                }
            }
        }
        #expect(checked == windows.count * sizes.count * 4 * 3 * remembered.count)
    }
}
