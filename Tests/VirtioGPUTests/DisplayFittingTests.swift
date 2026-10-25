import Testing

@testable import VirtioGPU

/// The display size the host starts with is brought within what the device allows to report.
struct DisplayFittingTests {
    struct Case: Sendable {
        let width: UInt32
        let height: UInt32
        let fitted: [UInt32]
    }

    static let cases = [
        Case(width: 1280, height: 800, fitted: [1280, 800]),
        Case(width: 3840, height: 2160, fitted: [3840, 2160]),
        Case(width: 5120, height: 2880, fitted: [5120, 2880]),
        Case(width: 0, height: 0, fitted: [1, 1]),
        Case(width: 0, height: 600, fitted: [1, 600]),
        Case(width: 4096, height: 4096, fitted: [4096, 4096]),
        Case(width: 8192, height: 2048, fitted: [8192, 2048]),
        Case(width: 8192, height: 8192, fitted: [4096, 4096]),
        Case(width: UInt32.max, height: 1, fitted: [8192, 1]),
    ]

    @Test(arguments: cases)
    func aSizeIsKeptWhenItFitsAndScaledDownWhenItDoesNot(size: Case) {
        let limits = GPULimits()
        let fitted = limits.fittingDisplay(width: size.width, height: size.height)
        #expect([fitted.width, fitted.height] == size.fitted)
        #expect(limits.allowsDisplay(width: fitted.width, height: fitted.height))
    }

    @Test
    func aLargeSizeIsScaledDownToTheBiggestPictureAResourceHoldsWithItsAspectRatio() {
        let limits = GPULimits()
        let fitted = limits.fittingDisplay(width: 7680, height: 4320)
        let bytes = Int(fitted.width) * Int(fitted.height) * GPUPixelFormat.bytesPerPixel
        #expect(bytes <= limits.maxResourceBytes && bytes > limits.maxResourceBytes * 99 / 100)
        #expect(abs(Double(fitted.width) / Double(fitted.height) - 16.0 / 9.0) < 0.01)
    }

    @Test
    func theResultFitsWhateverTheLimits() {
        var limits = GPULimits()
        limits.maxResourceBytes = 1 << 20
        limits.maxDisplaySide = 3000
        for (width, height) in [(5000, 5000), (3000, 3000), (2999, 1), (1024, 2000)] as [(UInt32, UInt32)] {
            let fitted = limits.fittingDisplay(width: width, height: height)
            #expect(limits.allowsDisplay(width: fitted.width, height: fitted.height), "\(width) x \(height)")
        }
    }
}
