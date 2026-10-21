import Foundation

/// A tiny SwiftPM package the gate runs against: a library with one tested and one untested function.
/// Passing state: swift-format clean, SwiftLint clean, builds, one passing test.
enum GateFixture {
    static let logic = """
        func add(_ left: Int, _ right: Int) -> Int {
          left + right
        }

        func untested(_ count: Int) -> Int {
          var total = 0
          for step in 0..<count {
            total += step
          }
          return total
        }

        """

    static let test = """
        import Testing

        @testable import Fixture

        @Test func addsNumbers() {
          #expect(add(2, 3) == 5)
        }

        """

    static var passing: [String: String] {
        [
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
              name: "Fixture",
              platforms: [.macOS(.v14)],
              targets: [
                .target(name: "Fixture"),
                .testTarget(name: "FixtureTests", dependencies: ["Fixture"]),
              ]
            )
            """,
            "Sources/Fixture/Logic.swift": logic,
            "Tests/FixtureTests/LogicTests.swift": test,
            ".swiftlint.yml": """
            strict: true
            included:
              - Sources
              - Tests
            only_rules:
              - force_unwrapping
            """,
        ]
    }

    /// The passing fixture with some files replaced.
    static func variant(_ replacements: [String: String]) -> [String: String] {
        passing.merging(replacements) { _, new in new }
    }

    /// Valid Swift that swift-format rejects.
    static let badlyFormatted = "func add(_ left:Int,_ right:Int)->Int{return left+right}\n"
    /// Well formatted Swift that does not compile.
    static let doesNotCompile = "func add(_ left: Int, _ right: Int) -> Int {\n  left + \"x\"\n}\n"
    /// Well formatted, compiling Swift that SwiftLint's `force_unwrapping` rejects.
    static let forceUnwrap = logic + "func firstOrZero(_ values: [Int]) -> Int {\n  let first: Int? = values.first\n  return first!\n}\n"
    /// A test that fails.
    static let failingTest = test.replacingOccurrences(of: "== 5", with: "== 6")
}
