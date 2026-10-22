/// A histogram of durations in nanoseconds with a fixed size, so recording never allocates.
///
/// Buckets are logarithmic with eight steps per doubling, so a percentile is exact to within about 12 percent of its value
/// (and exact below eight nanoseconds). Values from 2^40 ns (about 18 minutes) up share the last bucket. Alongside the
/// buckets it keeps the exact count, maximum and the number of values above ``threshold``, which the buckets cannot
/// answer precisely.
struct LatencyHistogram: Sendable, Equatable {
    private static let stepBits = 3
    private static let stepCount = 1 << stepBits
    private static let largestExponent = 40
    private static let bucketCount = (largestExponent - stepBits + 1) * stepCount

    /// Values strictly above this are counted in ``overThreshold``.
    let threshold: UInt64
    private(set) var samples: UInt64 = 0
    private(set) var maximum: UInt64 = 0
    private(set) var overThreshold: UInt64 = 0
    private var buckets = [UInt64](repeating: 0, count: Self.bucketCount)

    init(threshold: UInt64) { self.threshold = threshold }

    mutating func record(_ nanoseconds: UInt64) {
        buckets[Self.bucket(of: nanoseconds)] += 1
        samples += 1
        maximum = max(maximum, nanoseconds)
        if nanoseconds > threshold { overThreshold += 1 }
    }

    /// The smallest recorded value's bucket bound that covers `percent` of the values (0 when empty), never above ``maximum``.
    func percentile(_ percent: Double) -> UInt64 {
        guard samples > 0 else { return 0 }
        let wanted = (percent.isNaN ? 100 : min(max(percent, 0), 100)) / 100 * Double(samples)
        let rank = min(max(UInt64(wanted.rounded(.up)), 1), samples)
        var seen: UInt64 = 0
        for (index, inBucket) in buckets.enumerated() {
            seen += inBucket
            if seen >= rank { return min(Self.upperBound(ofBucket: index), maximum) }
        }
        return maximum
    }

    private static func bucket(of value: UInt64) -> Int {
        if value < UInt64(stepCount) { return Int(value) }
        let exponent = UInt64.bitWidth - 1 - value.leadingZeroBitCount
        let step = Int((value >> UInt64(exponent - stepBits)) & UInt64(stepCount - 1))
        return min(((exponent - stepBits + 1) << stepBits) | step, bucketCount - 1)
    }

    private static func upperBound(ofBucket index: Int) -> UInt64 {
        if index < stepCount { return UInt64(index) }
        let shift = UInt64((index >> stepBits) - 1)
        let lower = UInt64(stepCount + (index & (stepCount - 1))) << shift
        return lower + (1 << shift) - 1
    }
}
