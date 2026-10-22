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

    /// A locked control, disabled, beside a lock that says who locked it; an unlocked control as it is, so the form lays it
    /// out as it would without the modifier.
    @ViewBuilder
    private func lockedByOrganisation(_ isLocked: Bool) -> some View {
        if isLocked {
            HStack(alignment: .firstTextBaseline) {
                self.disabled(true)
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help(ManagedPreferences.lockedHelp)
                    .accessibilityLabel(ManagedPreferences.lockedHelp)
            }
        } else {
            self
        }
    }
}
