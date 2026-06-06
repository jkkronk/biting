import AppKit
import SwiftUI

/// Stable identifiers for the app's auxiliary `Window` scenes.
enum WindowID {
    static let onboarding = "onboarding"
}

/// Minimal `NSApplicationDelegate` adaptor.
///
/// Its job is the **first-run onboarding presentation** for an `LSUIElement` app: open the
/// onboarding window and perform the activation-policy dance (`.accessory` → `.regular`) so the
/// window can take focus and appear in front, then restore `.accessory` when onboarding ends.
@MainActor
final class ShooAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by ``ShooApp`` so the delegate can reach the shared state's ``WindowOpener`` and the
    /// `hasOnboarded` flag.
    weak var appState: AppState?

    /// Guards against opening the onboarding window twice (e.g. if both
    /// `applicationDidFinishLaunching` and a menu `.onAppear` race on a cold launch).
    private var didPresentOnboarding = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState else { return }
        if !appState.settings.hasOnboarded {
            presentOnboarding()
        }
        // Pick up permission/login-item changes whenever we come forward.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func didBecomeActive() {
        appState?.refreshCameraStatus()
    }

    /// Open the onboarding window, flip to `.regular` for a focusable, frontmost window.
    func presentOnboarding() {
        guard !didPresentOnboarding else { return }
        didPresentOnboarding = true
        NSApp.setActivationPolicy(.regular)
        appState?.windowOpener.open(id: WindowID.onboarding)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called when onboarding finishes or its window closes: return to a pure menu-bar agent.
    func finishOnboarding() {
        NSApp.setActivationPolicy(.accessory)
    }
}
