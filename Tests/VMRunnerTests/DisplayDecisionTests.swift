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

    // MARK: A stored size that cannot be a screen is not used

    private struct Stored: CustomTestStringConvertible {
        var width: Int
        var height: Int
        var testDescription: String { "\(width)x\(height)" }
    }

    private static let invalid = [
        Stored(width: 0, height: 0), Stored(width: -1920, height: -1200), Stored(width: 1920, height: 0),
        Stored(width: 0, height: 1200), Stored(width: 1, height: 1), Stored(width: 100, height: 100),
        Stored(width: 639, height: 800), Stored(width: 1280, height: 479), Stored(width: 100_000, height: 100_000),
        Stored(width: Int.min, height: Int.min), Stored(width: Int.max, height: Int.max),
    ]

    @Test(arguments: invalid)
    private func anInvalidFixedSizeFallsBackToTheWindowEvenWhenMatchWindowIsOff(stored: Stored) {
        let config = linux {
            $0.fitsWindowAtStart = false
            $0.displayWidth = stored.width
            $0.displayHeight = stored.height
        }
        let decision = StartDisplay.decide(for: config, window: retinaWindow, restoring: false)
        #expect(decision.source == .window && decision.width == 1280 && decision.height == 760, "\(decision)")
    }

    @Test(arguments: invalid)
    private func anInvalidConfiguredSizeFallsBackToTheGuestsDefaultWithoutAWindow(stored: Stored) {
        for fits in [true, false] {
            let linuxConfig = linux {
                $0.fitsWindowAtStart = fits
                $0.displayWidth = stored.width
                $0.displayHeight = stored.height
            }
            #expect(StartDisplay.decide(for: linuxConfig, window: nil, restoring: false).size == (1280, 800))
            var macConfig = VMConfig.new(name: "m", guest: .macOS)
            macConfig.fitsWindowAtStart = fits
            macConfig.displayWidth = stored.width
            macConfig.displayHeight = stored.height
            let decision = StartDisplay.decide(for: macConfig, window: nil, restoring: false)
            #expect(decision.size == (1920, 1200) && decision.source == .defaultSize)
        }
    }

    @Test func aFixedSizeThatTheGuestWouldKeepIsNotKeptWhenItIsInvalid() {
        let config = linux {
            $0.fitsWindowAtStart = false
            $0.automaticallyReconfiguresDisplay = false
            $0.displayWidth = 0
            $0.displayHeight = 0
        }
        let decision = StartDisplay.decide(for: config, window: retinaWindow, restoring: false)
        #expect(decision.source == .window && decision.width <= StartDisplay.legibleWidth)
    }

    @Test(arguments: invalid)
    private func anInvalidRememberedSizeIsNotRestoredInto(stored: Stored) {
        let config = linux {
            $0.lastDisplayWidth = stored.width
            $0.lastDisplayHeight = stored.height
        }
        let decision = StartDisplay.decide(for: config, window: retinaWindow, restoring: true)
        #expect(decision.source == .window && decision.width == 1280)
    }

    @Test func theLimitsOfTheEditorAreValidSizes() {
        let config = linux {
            $0.fitsWindowAtStart = false
            $0.automaticallyReconfiguresDisplay = false
            $0.displayWidth = EditorLimits.displayWidth.lowerBound
            $0.displayHeight = EditorLimits.displayHeight.lowerBound
        }
        #expect(StartDisplay.size(for: config, window: nil, restoring: false) == (640, 480))
        let largest = linux {
            $0.fitsWindowAtStart = false
            $0.automaticallyReconfiguresDisplay = false
            $0.displayWidth = EditorLimits.displayWidth.upperBound
            $0.displayHeight = EditorLimits.displayHeight.upperBound
        }
        #expect(StartDisplay.size(for: largest, window: nil, restoring: false) == (7680, 4320))
    }
}
