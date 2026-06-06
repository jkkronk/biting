import SwiftUI

/// The menu-bar popover. State-driven: it reflects watching / paused / snoozed / permission /
/// no-camera / outside-schedule states (``AppState/WatchState``) and offers the right primary
/// affordance for each, plus a daily reminders count, Settings, and Quit.
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            primaryControl
            statsLine

            Divider()

            footerButton("Settings…", shortcut: ",") { appState.presentSettings() }
            footerButton("Quit Shoo", shortcut: "q") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 270)
        .onAppear {
            // Re-check permission/login state and expose window actions to the AppDelegate.
            appState.refreshCameraStatus()
            appState.refreshTriggersToday()
            appState.windowOpener.open = { id in openWindow(id: id) }
            appState.windowOpener.dismiss = { id in dismissWindow(id: id) }
            // Hand the Settings action to AppState so it can do the activation dance.
            appState.openSettingsAction = { openSettings() }
        }
    }

    // MARK: - Footer buttons

    /// A full-width, left-aligned plain menu row with a ⌘ shortcut — gives the bottom of the
    /// popover a consistent, tidy look.
    private func footerButton(
        _ title: String,
        shortcut: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Shoo").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Primary control (state-dependent)

    @ViewBuilder
    private var primaryControl: some View {
        switch appState.effectiveState {
        case .needsPermission:
            Button("Grant Camera Access") {
                Task { await appState.requestCameraAccess() }
            }
            .controlSize(.large)

        case .permissionDenied:
            Button("Open System Settings…") {
                SystemSettings.openCameraPrivacy()
            }
            .controlSize(.large)

        case .noCamera:
            VStack(alignment: .leading, spacing: 6) {
                Text("No camera found. Connect a webcam.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Recheck") { appState.refreshCameraStatus() }
            }

        case .cameraError(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Recheck") { appState.refreshCameraStatus() }
            }

        case .snoozed(let until):
            VStack(alignment: .leading, spacing: 6) {
                Text("Snoozed until \(Self.timeFormatter.string(from: until))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Resume now") { appState.resume() }
            }

        case .outsideSchedule:
            VStack(alignment: .leading, spacing: 6) {
                Text("Paused by schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Watch anyway") { appState.overrideSchedule() }
            }

        case .watching, .paused:
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Watch for face-touching", isOn: Binding(
                    get: { appState.isWatching },
                    set: { _ in appState.toggleWatching() }
                ))
                .toggleStyle(.switch)

                if appState.isWatching {
                    snoozeMenu
                }
            }
        }
    }

    private var snoozeMenu: some View {
        Menu("Snooze") {
            Button("15 minutes") { appState.snooze(for: 15) }
            Button("30 minutes") { appState.snooze(for: 30) }
            Button("1 hour") { appState.snooze(for: 60) }
            Button("Until tomorrow morning") { appState.snoozeUntilTomorrowMorning() }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsLine: some View {
        if appState.triggersToday > 0 {
            Text("\(appState.triggersToday) reminder\(appState.triggersToday == 1 ? "" : "s") today")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived display

    private var statusColor: Color {
        switch appState.effectiveState {
        case .watching: return .green
        case .paused, .snoozed, .outsideSchedule: return .yellow
        case .needsPermission: return .orange
        case .permissionDenied, .noCamera, .cameraError: return .red
        }
    }

    private var statusText: String {
        switch appState.effectiveState {
        case .watching: return "Watching"
        case .paused: return "Paused"
        case .snoozed(let until): return "Snoozed until \(Self.timeFormatter.string(from: until))"
        case .needsPermission: return "Camera access needed"
        case .permissionDenied: return "Camera access denied"
        case .noCamera: return "No camera found"
        case .cameraError: return "Camera unavailable"
        case .outsideSchedule: return "Paused by schedule"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
