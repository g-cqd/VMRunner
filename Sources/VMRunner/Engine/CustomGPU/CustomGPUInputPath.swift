import Foundation

/// Which path carries the keyboard and pointer of a machine on the custom GPU: the framework's own input view, kept behind the
/// picture, or a virtio input device that the app implements. A developer default decides, not a setting in the app; the real
/// run against a guest is what chooses between the paths.
///
/// The value is read once, when a machine is prepared (`VZMachineFactory.prepare`), so changing it affects the next start only.
/// `defaults write <the app's bundle identifier> CustomGPUInput virtio` sets it. Any value but the two names, a value of
/// another type included, means `framework`.
enum CustomGPUInputPath: String, Sendable {
    case framework
    case virtio

    /// The key of the default in the app's defaults domain (`PreferencesDomain.defaults`).
    static let defaultsKey = "CustomGPUInput"

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .framework
    }

    static func current(in defaults: UserDefaults = PreferencesDomain.defaults) -> Self {
        Self(storedValue: defaults.string(forKey: defaultsKey))
    }

    /// The surface of this path for a machine, made on the main actor with the rest of the machine's custom GPU.
    @available(macOS 27.0, *)
    @MainActor
    func makeSurface() -> any GuestInputSurface {
        switch self {
        case .framework: FrameworkInputSurface()
        case .virtio: VirtioInputSurface()
        }
    }
}
