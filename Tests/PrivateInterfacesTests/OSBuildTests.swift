import Testing

@testable import PrivateInterfaces

/// The build number `kern.osversion` reports, as a value that can be ordered and kept to a range.
struct OSBuildTests {
    @Test
    func aReleaseBuildAndABetaBuildAreRead() throws {
        let release = try #require(OSBuild("26A434"))
        #expect(release == OSBuild(major: 26, letter: "A", count: 434))
        #expect(release.description == "26A434")
        let beta = try #require(OSBuild("26A5289g"))
        #expect(beta == OSBuild(major: 26, letter: "A", count: 5289), "the trailing letter of a beta takes no part in the order")
    }

    @Test(arguments: ["", "26", "A434", "26A", "26a434", "26A43x4", "26A434gg", "26A434G", "26 A434", "２６A434", "-26A434"])
    func aTextThatIsNotABuildIsRefused(text: String) {
        #expect(OSBuild(text) == nil, "\(text)")
    }

    @Test
    func buildsAreOrderedByVersionThenLetterThenCount() throws {
        let order = try ["25H100", "26A1", "26A434", "26A5289g", "26B1", "27A1"].map { try #require(OSBuild($0)) }
        #expect(order == order.sorted())
        #expect(order[2] < order[3] && order[3] < order[4])
        let nine = try #require(OSBuild("9Z9"))
        let ten = try #require(OSBuild("10A1"))
        #expect(nine < ten, "versions compare as numbers, not as text")
    }

    @Test
    func theRunningBuildReadsAsABuild() throws {
        let running = try #require(OSBuild.running, "this Mac reports kern.osversion")
        #expect(OSBuild(running) != nil, "\(running)")
    }
}
