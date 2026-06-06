import SwiftUI

/// Preferences window: a tabbed surface (Detection / Reminders / Schedule / General / About)
/// over the shared ``AppSettings``. Each tab is a small grouped `Form`.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            DetectionTab(settings: appState.settings)
                .tabItem { Label("Detection", systemImage: "eye") }
            RemindersTab(settings: appState.settings)
                .tabItem { Label("Reminders", systemImage: "bell") }
            ScheduleTab(settings: appState.settings)
                .tabItem { Label("Schedule", systemImage: "calendar") }
            GeneralTab(settings: appState.settings)
                .environmentObject(appState)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutTab()
                .environmentObject(appState)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460)
    }
}

// MARK: - Detection

private struct DetectionTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Detection") {
                VStack(alignment: .leading) {
                    Text("Sensitivity")
                    Slider(value: $settings.sensitivity, in: 0...1)
                    Text("Higher sensitivity triggers earlier, but may cause more false alarms.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Watched gestures") {
                gestureToggle("Nail biting", .nailBiting)
                gestureToggle("Nose picking", .nosePicking)
                gestureToggle("Lip biting", .lipBiting)
                gestureToggle("Hair pulling", .hairPulling)
                Text("Which face-touching habits Shoo should flag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }

    private func gestureToggle(_ label: String, _ gesture: GestureMask) -> some View {
        Toggle(label, isOn: Binding(
            get: { settings.watchedGestures.contains(gesture) },
            set: { isOn in
                if isOn { settings.watchedGestures.insert(gesture) }
                else { settings.watchedGestures.remove(gesture) }
            }
        ))
    }
}

// MARK: - Reminders

private struct RemindersTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
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

            Section("How you're reminded") {
                Toggle("Show overlay", isOn: $settings.overlayEnabled)
                Toggle("Play a sound", isOn: $settings.soundEnabled)
                Toggle("Show a notification", isOn: $settings.notificationEnabled)
                Toggle("Escalate if it persists", isOn: $settings.escalationEnabled)
                Text("The overlay is the primary reminder; sound and notifications are optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}

// MARK: - Schedule

private struct ScheduleTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Only watch during active hours", isOn: $settings.scheduleEnabled)
            }

            Section("Days") {
                ForEach(Self.weekdays, id: \.day.rawValue) { entry in
                    Toggle(entry.label, isOn: weekdayBinding(entry.day))
                }
            }
            .disabled(!settings.scheduleEnabled)

            Section("Hours") {
                DatePicker(
                    "Start",
                    selection: minutesBinding(\.activeStartMinutes),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "End",
                    selection: minutesBinding(\.activeEndMinutes),
                    displayedComponents: .hourAndMinute
                )
                Text("If end is earlier than start, the window runs overnight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.scheduleEnabled)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }

    private static let weekdays: [(label: String, day: WeekdaySet)] = [
        ("Sunday", .sunday), ("Monday", .monday), ("Tuesday", .tuesday),
        ("Wednesday", .wednesday), ("Thursday", .thursday), ("Friday", .friday),
        ("Saturday", .saturday),
    ]

    private func weekdayBinding(_ day: WeekdaySet) -> Binding<Bool> {
        Binding(
            get: { settings.activeWeekdays.contains(day) },
            set: { isOn in
                if isOn { settings.activeWeekdays.insert(day) }
                else { settings.activeWeekdays.remove(day) }
            }
        )
    }

    /// Bridge a minutes-since-midnight `Int` setting to a `Date` for `DatePicker`.
    private func minutesBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = settings[keyPath: keyPath]
                let calendar = Calendar.current
                return calendar.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            }
        )
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var settings: AppSettings

    @State private var loginItemState: LaunchAtLogin.State = LaunchAtLogin.state
    @State private var loginItemError = false
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItemState == .enabled },
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

            Section {
                Button("Reset to Defaults…", role: .destructive) {
                    showResetConfirm = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .onAppear { syncLoginItem() }
        .alert("Reset all settings to defaults?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
                _ = LaunchAtLogin.setEnabled(settings.launchAtLogin)
                syncLoginItem()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores detection, reminder, schedule, and general settings.")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = false
        switch LaunchAtLogin.setEnabled(enabled) {
        case .success(let resultState):
            loginItemState = resultState
        case .failure:
            loginItemError = true
        }
        // Re-read authoritatively and mirror into settings.
        loginItemState = LaunchAtLogin.state
        appState.syncLaunchAtLogin()
    }

    private func syncLoginItem() {
        loginItemState = LaunchAtLogin.state
        appState.syncLaunchAtLogin()
    }
}

// MARK: - About

private struct AboutTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
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
                Link(
                    "Privacy Policy",
                    destination: URL(string: "https://github.com/jonatank/shoo/blob/main/docs/PRIVACY.md")!
                )
            }

            Section("Acknowledgements") {
                Text("No third-party code; built with Apple Vision, SwiftUI, and ServiceManagement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Show onboarding again") {
                    appState.settings.hasOnboarded = false
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
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
