import AppKit
import Foundation

/// Watches screen-lock, display/system sleep, thermal pressure, and low-power mode,
/// and drives the camera's pause/resume + frame-rate policy accordingly.
///
/// Pausing means `session.stopRunning()` (camera LED off, real power/privacy savings)
/// while the user's intent (`isWatching`) is preserved so we resume on the inverse
/// event. Overlapping causes are handled by ``CameraController``'s reference-counted
/// pause set, so this coordinator just translates events into `pause/resume(reason:)`.
@MainActor
final class PowerCoordinator {
    /// The frame source we pause/resume and re-throttle.
    var frameSource: FrameSource?

    /// Normal capture rate; restored when thermal/low-power pressure clears.
    private let baseFPS: Int
    /// Reduced rate under serious thermal pressure or low-power mode.
    private let reducedFPS: Int

    private var observers: [NSObjectProtocol] = []

    init(frameSource: FrameSource? = nil,
         baseFPS: Int = CameraController.defaultTargetFPS,
         reducedFPS: Int = 6) {
        self.frameSource = frameSource
        self.baseFPS = baseFPS
        self.reducedFPS = reducedFPS
        registerObservers()
        applyThrottlePolicy()  // honor whatever state we launched into
    }

    // MARK: - Observer registration

    private func registerObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()

        // Handlers hop via `Task { @MainActor in }` rather than `MainActor.assumeIsolated`:
        // some `ProcessInfo` notifications are not guaranteed to honor `queue: .main`, and
        // `assumeIsolated` would trap if one ever arrived off-main. These events aren't
        // ordering-sensitive, so the async hop is harmless.

        // Display sleep/wake.
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.frameSource?.pause(.displayAsleep) } })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.frameSource?.resume(.displayAsleep) } })

        // System sleep/wake — release the camera cleanly before suspend.
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.frameSource?.pause(.systemAsleep) } })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.frameSource?.resume(.systemAsleep) } })

        // Screen lock/unlock (read-only distributed notifications; allowed under sandbox).
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.frameSource?.pause(.screenLocked) } })
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.frameSource?.resume(.screenLocked) } })

        // Thermal pressure.
        observers.append(defaultCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleThermalChange() } })

        // Low-power mode.
        observers.append(defaultCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.applyThrottlePolicy() } })
    }

    // MARK: - Thermal / low-power policy

    private func handleThermalChange() {
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            // Only critical pauses capture; serious merely throttles (handled below).
            frameSource?.pause(.thermal)
        default:
            frameSource?.resume(.thermal)
        }
        applyThrottlePolicy()
    }

    /// Pick the capture FPS based on combined thermal + low-power pressure.
    private func applyThrottlePolicy() {
        let thermal = ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let underPressure = lowPower || thermal == .serious || thermal == .critical
        frameSource?.setTargetFPS(underPressure ? reducedFPS : baseFPS)
    }

    deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        for observer in observers {
            workspaceCenter.removeObserver(observer)
            defaultCenter.removeObserver(observer)
            distributed.removeObserver(observer)
        }
    }
}
