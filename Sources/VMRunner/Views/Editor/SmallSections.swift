import SwiftUI

/// Pointing device and keyboard capture.
struct InputSection: View {
    let guest: GuestOS
    @Binding var pointing: PointingDevice
    @Binding var capturesSystemKeys: Bool

    var body: some View {
        Section {
            if guest == .macOS {
                Picker("Pointing device", selection: $pointing) {
                    ForEach(PointingDevice.allCases) { Text($0.label).tag($0) }
                }
                .settingHelp(.pointingDevice)
                Text("Trackpad enables gestures and needs a macOS 13+ guest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Capture system keyboard shortcuts", isOn: $capturesSystemKeys)
                .settingHelp(.captureKeys)
        } header: {
            HelpHeader("Input", topic: .captureKeys)
        }
    }
}

/// Sound output and microphone input.
struct AudioSection: View {
    @Binding var output: Bool
    @Binding var input: Bool

    var body: some View {
        Section {
            Toggle("Sound output", isOn: $output).help(HelpTopic.audio.summary)
            Toggle("Microphone input", isOn: $input)
                .managedLock(.allowMicrophone)
                .help("The guest can record from your Mac's microphone. Leave off unless needed.")
        } header: {
            HelpHeader("Audio", topic: .audio)
        }
    }
}

/// The helper devices the guest can use.
struct DevicesSection: View {
    @Binding var balloon: Bool
    @Binding var entropy: Bool
    @Binding var vsock: Bool
    @Binding var serialConsole: Bool
    let guest: GuestOS

    var body: some View {
        Section {
            Toggle("Memory balloon", isOn: $balloon).settingHelp(.memoryBalloon)
            Toggle("Entropy (virtio-rng)", isOn: $entropy).settingHelp(.entropy)
            Toggle("Host–guest socket (vsock)", isOn: $vsock).settingHelp(.vsock)
            Toggle("Serial console (local socket)", isOn: guest == .linux ? $serialConsole : .constant(false))
                .disabled(guest != .linux)
                .settingHelp(.serialConsole)
            if guest == .macOS {
                Text("Not available for macOS guests.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HelpHeader("Devices", topic: .devices)
        }
    }
}

/// macOS Recovery boot and the first-boot account.
struct BootSection: View {
    @Binding var recovery: Bool
    let hasBooted: Bool
    @Binding var provisioning: Provisioning

    var body: some View {
        Section {
            Toggle("Start in macOS Recovery", isOn: $recovery).settingHelp(.bootRecovery)
        } header: {
            HelpHeader("Boot", topic: .bootRecovery)
        }
        if !hasBooted, #available(macOS 27.0, *) {
            Section {
                Toggle("Create account automatically", isOn: $provisioning.enabled)
                if provisioning.enabled {
                    TextField("Full name", text: $provisioning.fullName.limited())
                    TextField("Username", text: $provisioning.username.limited())
                    SecureField("Password", text: $provisioning.password)
                    Toggle("Log in automatically", isOn: $provisioning.logsInAutomatically)
                    Toggle("Enable Remote Login (SSH)", isOn: $provisioning.enablesRemoteLogin)
                    Text(
                        "Skips Setup Assistant on a macOS 27 guest. The password is kept in memory only; "
                            + "re-enter it if you relaunch before the first boot."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HelpHeader("First-boot account", topic: .firstBootAccount)
            }
        }
    }
}
