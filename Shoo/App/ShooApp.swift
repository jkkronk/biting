import SwiftUI

/// Entry point. Shoo is a menu-bar agent (no dock icon — see `LSUIElement` in Info.plist).
///
/// The app owns a single ``AppState`` that wires the camera → detector → alert pipeline.
/// The UI is a `MenuBarExtra`, a standard `Settings` scene, and a dedicated onboarding
/// `Window` (presented once on first run; see ``ShooAppDelegate``).
@main
struct ShooApp: App {
    @NSApplicationDelegateAdaptor(ShooAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Shoo", systemImage: appState.menuBarSymbolName) {
            MenuBarView()
                .environmentObject(appState)
                // Capture window actions for the AppDelegate, and wire the onboarding-finish
                // hook, the first time the menu content appears.
                .onAppear { wireWindowActions() }
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Shoo", id: WindowID.onboarding) {
            OnboardingView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    /// Bridge SwiftUI's environment actions to ``AppState`` so the (non-SwiftUI) AppDelegate
    /// can open/close the onboarding window, and connect the activation-policy restore hook.
    @MainActor
    private func wireWindowActions() {
        appDelegate.appState = appState
        appState.onOnboardingFinished = { [weak appDelegate] in
            appDelegate?.finishOnboarding()
        }
        appState.refreshCameraStatus()
    }
}
