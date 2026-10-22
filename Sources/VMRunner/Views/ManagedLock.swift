import SwiftUI

extension View {
    /// Disables the control when the organisation restricted `key`, and shows a lock that says so. Put it before
    /// `.settingHelp`, so the help button stays usable.
    func managedLock(_ key: ManagedKey, in policy: ManagedPreferences = .current) -> some View {
        lockedByOrganisation(policy.isLocked(key))
    }

    /// Disables the control of one of the app's own settings when the organisation forced its value, with the same lock.
    func managedLock(_ setting: AppSetting, in policy: ManagedPreferences = .current) -> some View {
        lockedByOrganisation(policy.isLocked(setting))
    }

    private func lockedByOrganisation(_ isLocked: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            self.disabled(isLocked)
            if isLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help(ManagedPreferences.lockedHelp)
                    .accessibilityLabel(ManagedPreferences.lockedHelp)
            }
        }
    }
}
