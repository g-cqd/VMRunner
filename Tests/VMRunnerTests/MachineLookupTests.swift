import Foundation
import Testing

@testable import VMRunner

struct MachineLookupTests {
    private func machine(_ name: String) -> VMConfig { VMConfig.new(name: name, guest: .linux) }

    @Test func aUniqueNameFindsItsMachine() {
        let target = machine("build")
        let machines = [machine("other"), target]

        #expect(MachineLookup.resolve("build", in: machines) == .found(target.id))
    }

    @Test func anIDFindsItsMachineEvenWhenNamesRepeat() {
        let first = machine("dup")
        let second = machine("dup")

        #expect(MachineLookup.resolve(second.id.uuidString, in: [first, second]) == .found(second.id))
        #expect(MachineLookup.resolve(second.id.uuidString.lowercased(), in: [first, second]) == .found(second.id))
    }

    @Test func anIDBeatsAMachineNamedLikeIt() {
        let real = machine("real")
        let decoy = machine(real.id.uuidString)

        #expect(MachineLookup.resolve(real.id.uuidString, in: [decoy, real]) == .found(real.id))
    }

    @Test func severalMachinesWithTheNameAreAmbiguous() {
        let machines = [machine("dup"), machine("dup"), machine("dup"), machine("solo")]

        #expect(MachineLookup.resolve("dup", in: machines) == .ambiguous(count: 3))
    }

    @Test(arguments: ["missing", "", "3B873409-1F62-435C-A557-0040D55FBE19"])
    func anUnknownKeyIsNotFound(key: String) {
        #expect(MachineLookup.resolve(key, in: [machine("a"), machine("b")]) == .notFound)
    }
}
