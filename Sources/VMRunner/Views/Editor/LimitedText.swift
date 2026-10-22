import SwiftUI

extension Binding where Value == String {
    /// A binding that cuts what is typed or pasted at `limit` characters, so a field cannot hold what a stored configuration
    /// (`VMConfig.validate()`) would refuse.
    func limited(to limit: Int = EditorLimits.maxTextLength) -> Binding<String> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0.count > limit ? String($0.prefix(limit)) : $0 })
    }
}
