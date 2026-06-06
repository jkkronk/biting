import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "launch at login" preference.
///
/// `SMAppService.mainApp` registers the *main app itself* as a login item — fully supported
/// for sandboxed Mac App Store apps (no helper executable, no `SMPrivilegedExecutables`).
enum LaunchAtLogin {
    /// The login-item state, mapped from `SMAppService.Status` into something the UI can
    /// reason about (notably surfacing `.requiresApproval`).
    enum State: Equatable {
        /// Registered and active.
        case enabled
        /// Registered but the user must approve it in System Settings ▸ Login Items.
        case requiresApproval
        /// Not registered (the default).
        case notRegistered
        /// Service-management is unavailable (e.g. not found / unknown future status).
        case unavailable

        init(_ status: SMAppService.Status) {
            switch status {
            case .enabled: self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notRegistered: self = .notRegistered
            case .notFound: self = .unavailable
            @unknown default: self = .unavailable
            }
        }
    }

    /// Current state, read live from `SMAppService` (the authoritative source — never trust an
    /// optimistic local value).
    static var state: State {
        State(SMAppService.mainApp.status)
    }

    /// Whether the login item is active right now.
    static var isEnabled: Bool {
        state == .enabled
    }

    /// Register or unregister, returning the *resulting* state (re-read from `SMAppService`)
    /// so the UI can react authoritatively — including the common `.requiresApproval` case
    /// after a first registration.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<State, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(state)
        } catch {
            AppLogger.app.error("Failed to update launch-at-login: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    /// Open System Settings ▸ General ▸ Login Items so the user can approve a pending item.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
