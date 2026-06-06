import AppKit

/// Deep-links into the relevant panes of System Settings.
///
/// Opening these URLs via `NSWorkspace` is permitted under the App Sandbox and does **not**
/// require the network entitlement.
enum SystemSettings {
    /// Open System Settings → Privacy & Security → Camera so a denied/undetermined user can
    /// grant access. Tries the newer (macOS 13+) URL first, then the legacy one.
    @MainActor
    static func openCameraPrivacy() {
        let candidates = [
            // Newer System Settings (Ventura+).
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera",
            // Legacy.
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
            "x-apple.systempreferences:Privacy_Camera",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
