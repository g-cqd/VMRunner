import Foundation

/// The steps of the quality gate and the sets `vmr check` runs by default.
enum GateCatalog {
    static let fastSteps: [GateStep] = [
        GateStep(name: "format", run: GateSteps.format),
        GateStep(name: "swiftlint", run: GateSteps.swiftlint),
        GateStep(name: "build", run: GateSteps.build),
        GateStep(name: "test", run: GateSteps.test),
        GateStep(name: "analyzers", run: GateSteps.analyzers),
    ]

    static let fullOnlySteps: [GateStep] = [
        GateStep(name: "asan", run: GateSteps.sanitizer("address", scratch: ".build-asan")),
        GateStep(name: "tsan", run: GateSteps.sanitizer("thread", scratch: ".build-tsan")),
        GateStep(
            name: "ubsan", run: GateSteps.sanitizer("undefined", scratch: ".build-ubsan", linkerArguments: GateSteps.ubsanLinkerArguments)),
        GateStep(name: "release", run: GateSteps.release),
        GateStep(name: "coverage", run: GateSteps.coverage),
    ]

    static var allSteps: [GateStep] { fastSteps + fullOnlySteps }

    static func step(named name: String) -> GateStep? {
        allSteps.first { $0.name == name }
    }
}
