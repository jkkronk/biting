import SwiftUI

/// Preferences window: a single grouped settings page over the shared ``AppSettings``,
/// covering sensitivity, timing, reminders, startup, reset, and about.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsForm(settings: appState.settings)
            .environmentObject(appState)
    }
}

/// The actual page. Split out so it can observe ``AppSettings`` directly via `@ObservedObject`,
/// which keeps the `$settings.…` bindings live as values change.
private struct SettingsForm: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var settings: AppSettings

    @State private var loginItemState: LaunchAtLogin.State = LaunchAtLogin.state
    @State private var loginItemError = false
    @State private var showResetConfirm = false
    @State private var showPrivacy = false

    var body: some View {
        Form {
            sensitivitySection
            timingSection
            remindersSection
            startupSection
            resetSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { syncLoginItem() }
        .sheet(isPresented: $showPrivacy) { PrivacyPolicyView() }
        .alert("Reset all settings to defaults?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
                _ = LaunchAtLogin.setEnabled(settings.launchAtLogin)
                syncLoginItem()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores all settings to their defaults.")
        }
    }

    // MARK: - Sections

    private var sensitivitySection: some View {
        Section("Sensitivity") {
            VStack(alignment: .leading) {
                Slider(value: $settings.sensitivity, in: 0...1)
                Text("Higher sensitivity triggers earlier, but may cause more false alarms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timingSection: some View {
        Section("Timing") {
            Stepper(
                "Cooldown: \(Int(settings.cooldownSeconds)) s",
                value: $settings.cooldownSeconds,
                in: 1...60
            )
            Text("Minimum time between two reminders.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var remindersSection: some View {
        Section("How you're reminded") {
            Toggle("Show overlay", isOn: $settings.overlayEnabled)
            Toggle("Play a sound", isOn: $settings.soundEnabled)
            Toggle("Show a notification", isOn: $settings.notificationEnabled)
            Toggle("Show camera snapshot in reminder", isOn: $settings.snapshotInReminderEnabled)
            Text("The overlay is the primary reminder; sound and notifications are optional. "
                + "The snapshot shows a quick photo of the moment (falls back to an icon when off).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var startupSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: Binding(
                // `.requiresApproval` means the user enabled it but macOS wants confirmation —
                // treat it as "on" (intent) so the toggle doesn't snap back; the banner below
                // points to System Settings.
                get: { loginItemState == .enabled || loginItemState == .requiresApproval },
                set: { setLaunchAtLogin($0) }
            ))
            Toggle("Start watching on launch", isOn: $settings.startWatchingOnLaunch)

            if loginItemState == .requiresApproval {
                HStack {
                    Text("Login item needs approval in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open…") { LaunchAtLogin.openLoginItemsSettings() }
                }
            }
            if loginItemError {
                Text("Couldn't update Login Items — open System Settings.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to Defaults…", role: .destructive) {
                showResetConfirm = true
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            VStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text(AppInfo.displayName).font(.title2.weight(.semibold))
                Text(AppInfo.versionDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }

        Section {
            Button("Privacy Policy") { showPrivacy = true }
        }

        Section("Acknowledgements") {
            Text("No third-party code; built with Apple Vision, SwiftUI, and ServiceManagement.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Button("Show onboarding again") {
                settings.hasOnboarded = false
                NSApp.setActivationPolicy(.regular)
                appState.windowOpener.open(id: WindowID.onboarding)
                NSApp.activate(ignoringOtherApps: true)
            }
            if !AppInfo.copyright.isEmpty {
                Text(AppInfo.copyright)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Login item

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = false
        switch LaunchAtLogin.setEnabled(enabled) {
        case .success(let resultState):
            // Trust the result; don't immediately re-read SMAppService.status, which can lag
            // right after register()/unregister() and would clobber the true outcome.
            loginItemState = resultState
        case .failure:
            // Keep the prior state (don't flip the toggle) and surface the error banner.
            loginItemError = true
        }
        appState.syncLaunchAtLogin()
    }

    private func syncLoginItem() {
        loginItemState = LaunchAtLogin.state
        appState.syncLaunchAtLogin()
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
