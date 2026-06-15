import AVFoundation
import CoreVideo
import Foundation
import ImageIO

/// Owns the `AVCaptureSession` and delivers raw camera frames to a callback.
///
/// All AVFoundation work happens on a private serial `sessionQueue`; lifecycle/auth/
/// device transitions are reported through ``FrameSource/onStateChange`` on the main
/// actor. Frames are **downscaled into an owned buffer on `sessionQueue`** before being
/// handed off, so consumers on other queues never touch the capture-owned surface.
///
/// The session runs **iff** `isWatching` && authorized && no active pause reasons —
/// see ``shouldBeRunning``. This keeps the green camera indicator on only while we
/// are genuinely watching.
final class CameraController: NSObject, FrameSource {
    /// Called for every delivered frame, on `sessionQueue`, with the orientation derived
    /// from the active capture connection.
    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?

    /// Called for every state transition, hopped onto the main actor.
    var onStateChange: ((CameraSessionState) -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.shoo.camera.session")

    private var videoInput: AVCaptureDeviceInput?
    private var activeDevice: AVCaptureDevice?
    private var isConfigured = false
    private var observersRegistered = false

    /// User intent: the caller wants us watching. Toggled by `start()`/`stop()`.
    private var wantsToWatch = false
    /// Active auto-pause reasons; the session runs only when this is empty.
    private var pauseReasons = PauseReasonSet()

    /// Default capture/processing rate; single source of truth for both the device cap and the
    /// software throttle so they can't silently diverge.
    static let defaultTargetFPS = 12

    /// Capture frame-rate cap (lowered under thermal/low-power pressure).
    private var targetFPS = CameraController.defaultTargetFPS

    /// Software gate that admits at most `targetFPS` frames/sec to the detector and drops
    /// the rest — a backstop in case the device delivers above the requested cap. Touched
    /// only on `sessionQueue` (where frames arrive).
    private let frameThrottle = FrameThrottle(targetFPS: CameraController.defaultTargetFPS)

    /// Shrinks each accepted frame into a pool-owned buffer on `sessionQueue` before hand-off,
    /// so the capture-owned source surface is never read after the delegate returns.
    private let downscaler = FrameDownscaler()

    /// Bounded auto-restart bookkeeping for transient runtime errors.
    private var restartAttempts = 0
    private let maxRestartAttempts = 4
    private var restartWindowStart = Date.distantPast
    /// Bumped on every successful (re)start; pending backoff blocks captured under an older
    /// generation bail, so a recovered session isn't torn down by a stale retry.
    private var restartGeneration = 0

    // MARK: - FrameSource

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsToWatch = true
            self.startIfNeeded()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsToWatch = false
            self.pauseReasons.clear()
            self.stopRunningIfNeeded()
            self.emit(.idle)
        }
    }

    func pause(_ reason: CameraSessionState.PauseReason) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.pauseReasons.insert(reason)
            self.reconcileRunState()
        }
    }

    func resume(_ reason: CameraSessionState.PauseReason) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.pauseReasons.remove(reason)
            self.reconcileRunState()
        }
    }

    func setTargetFPS(_ fps: Int) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.targetFPS = max(1, fps)
            self.frameThrottle.setTargetFPS(self.targetFPS)
            self.applyFrameRateCap()
        }
    }

    // MARK: - Run-state reconciliation (sessionQueue only)

    /// The session should be live only when the user wants to watch and nothing is pausing us.
    private var shouldBeRunning: Bool {
        wantsToWatch && !pauseReasons.isPaused
    }

    private func startIfNeeded() {
        guard shouldBeRunning else { return }
        emit(.starting)

        if !isConfigured {
            configure()
        }
        // `configure()` emits `.noDevice` and leaves `isConfigured` false on failure.
        guard isConfigured else { return }

        if !session.isRunning {
            session.startRunning()
        }
        emit(.running)
        markRunningSucceeded()
    }

    /// Reset restart bookkeeping after a healthy (re)start so spaced-out transient errors
    /// don't accumulate toward the terminal `.failed`, and cancel any pending backoff retry.
    private func markRunningSucceeded() {
        restartAttempts = 0
        restartWindowStart = Date()
        restartGeneration &+= 1
    }

    /// Bring the session into line with `shouldBeRunning` without changing user intent.
    private func reconcileRunState() {
        if shouldBeRunning {
            startIfNeeded()
        } else if session.isRunning {
            session.stopRunning()
            if let reason = pauseReasons.primaryReason, wantsToWatch {
                AppLogger.camera.notice("Auto-paused capture: \(reason.description, privacy: .public)")
                emit(.pausedAuto(reason))
            } else {
                emit(.idle)
            }
        } else if wantsToWatch, let reason = pauseReasons.primaryReason {
            emit(.pausedAuto(reason))
        }
    }

    private func stopRunningIfNeeded() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    // MARK: - Configuration (sessionQueue only)

    private func configure() {
        guard let device = DeviceSelector.selectDevice() else {
            AppLogger.camera.error("No usable camera device discovered")
            emit(.noDevice)
            return
        }

        session.beginConfiguration()
        // ≈480p is enough for face+hand Vision at arm's length. Guard the assignment: setting
        // an unsupported preset raises an exception, so fall back to the session default.
        if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        guard
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            AppLogger.camera.error("Failed to create/add input for \(device.localizedName, privacy: .public)")
            session.commitConfiguration()
            emit(.noDevice)
            return
        }
        session.addInput(input)
        videoInput = input
        activeDevice = device
        // Persist the chosen device so selection is stable across launches.
        UserDefaults.standard.set(device.uniqueID, forKey: DeviceSelector.storedDeviceIDKey)

        // Output: raw pixel buffers on our serial queue. Pin BGRA so Core Image (the
        // detector's downscaler) and Vision get a predictable format with no surprise
        // per-frame conversion.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            session.addOutput(videoOutput)
        } else if !session.outputs.contains(videoOutput) {
            // Only legitimate to skip when the output is already attached (reconfigure
            // path — tearDownConfiguration keeps it). Otherwise the session would "run"
            // with the LED on but deliver no frames and surface no error.
            AppLogger.camera.error("Cannot attach video output for \(device.localizedName, privacy: .public)")
            session.commitConfiguration()
            emit(.failed("Camera doesn't support video capture"))
            return  // leaves isConfigured == false, like the input-failure path
        }

        session.commitConfiguration()

        applyFrameRateCap()
        isConfigured = true
        AppLogger.camera.info("Configured capture with \(device.localizedName, privacy: .public)")

        registerObservers()
    }

    /// Remove inputs/outputs so the next `configure()` rebuilds from scratch (disconnect path).
    private func tearDownConfiguration() {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        session.commitConfiguration()
        videoInput = nil
        activeDevice = nil
        isConfigured = false
    }

    /// Cap the capture frame rate via the device's active video frame durations.
    ///
    /// The requested fps is clamped into the active format's supported ranges *before* it's
    /// applied — setting a duration outside the supported range raises an uncatchable
    /// Objective-C exception. When the target is below the device floor (e.g. 12 fps on a
    /// 15–30 fps camera), the software `FrameThrottle` still governs the detector's cadence.
    private func applyFrameRateCap() {
        guard let device = activeDevice else { return }
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
            .map { (min: $0.minFrameRate, max: $0.maxFrameRate) }
        guard let capped = FrameRateCap.clamp(desiredFPS: Double(targetFPS), into: ranges) else {
            // No usable ranges reported — leave the device default rather than force a value.
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = capped.duration
            device.activeVideoMaxFrameDuration = capped.duration
            device.unlockForConfiguration()
            let detail = "Capped capture to \(capped.fps) fps (requested \(self.targetFPS))"
            AppLogger.camera.info("\(detail, privacy: .public)")
        } catch {
            AppLogger.camera.error("Failed to cap frame rate: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Observers

    private func registerObservers() {
        guard !observersRegistered else { return }
        observersRegistered = true
        let center = NotificationCenter.default

        center.addObserver(
            self, selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(
            self, selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session)
        center.addObserver(
            self, selector: #selector(deviceWasDisconnected(_:)),
            name: .AVCaptureDeviceWasDisconnected, object: nil)
        center.addObserver(
            self, selector: #selector(deviceWasConnected(_:)),
            name: .AVCaptureDeviceWasConnected, object: nil)
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        // `AVCaptureSession.InterruptionReason` is iOS-only; on macOS the common cause
        // is another app grabbing the camera. Surface a generic, human-readable string.
        // Hop onto sessionQueue like the other handlers so all session access + emit are
        // serialized in one domain (AV delivers notifications on an arbitrary thread).
        sessionQueue.async { [weak self] in
            let reason = "Camera in use by another app"
            AppLogger.camera.notice("Session interrupted: \(reason, privacy: .public)")
            self?.emit(.interrupted(reason))
        }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        AppLogger.camera.info("Session interruption ended")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.shouldBeRunning {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.emit(.running)
                self.markRunningSucceeded()
            }
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
        AppLogger.camera.error("Session runtime error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.attemptBoundedRestart(after: error)
        }
    }

    @objc private func deviceWasDisconnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice else { return }
        sessionQueue.async { [weak self] in
            guard let self, device.uniqueID == self.activeDevice?.uniqueID else { return }
            AppLogger.camera.notice("Active camera disconnected; reselecting")
            self.tearDownConfiguration()
            // Reconfigure with the next-best device (or surface .noDevice) and restart.
            self.startIfNeeded()
            if !self.isConfigured && self.wantsToWatch {
                self.emit(.noDevice)
            }
        }
    }

    @objc private func deviceWasConnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.wantsToWatch else { return }
            // Skip if the newcomer is already our active device (spurious re-enumeration) —
            // tearing down a healthy session would flicker the LED and drop frames.
            guard device.uniqueID != self.activeDevice?.uniqueID else { return }
            // Reconfigure if we currently have no device, or the newcomer is the preferred one.
            let preferredID = UserDefaults.standard.string(forKey: DeviceSelector.storedDeviceIDKey)
            let isPreferred = preferredID != nil && device.uniqueID == preferredID
            if !self.isConfigured || isPreferred {
                AppLogger.camera.notice("Camera connected; reconfiguring")
                self.tearDownConfiguration()
                self.startIfNeeded()
            }
        }
    }

    /// Restart with exponential backoff for transient errors, bounded to avoid thrash.
    private func attemptBoundedRestart(after error: AVError?) {
        // Reset the attempt window after a quiet period.
        if Date().timeIntervalSince(restartWindowStart) > 30 {
            restartAttempts = 0
            restartWindowStart = Date()
        }

        guard restartAttempts < maxRestartAttempts else {
            let message = error?.localizedDescription ?? "Camera failure"
            AppLogger.camera.error("Restart attempts exhausted; failing: \(message, privacy: .public)")
            emit(.failed(message))
            return
        }

        restartAttempts += 1
        let backoff = min(pow(2.0, Double(restartAttempts - 1)) * 0.5, 4.0)  // 0.5, 1, 2, 4
        let detail = "Auto-restart attempt \(self.restartAttempts) in \(backoff)s"
        AppLogger.camera.notice("\(detail, privacy: .public)")

        let generation = restartGeneration
        sessionQueue.asyncAfter(deadline: .now() + backoff) { [weak self] in
            // Bail if a successful (re)start happened in the meantime, or we shouldn't run.
            guard let self, self.restartGeneration == generation, self.shouldBeRunning else { return }
            self.tearDownConfiguration()
            self.startIfNeeded()
        }
    }

    // MARK: - State emission

    /// Forward a state transition to the main actor. Uses `DispatchQueue.main.async` (FIFO) so
    /// transitions arrive in the order emitted — unstructured `Task`s are not ordered and could
    /// deliver e.g. `.running` before `.starting`.
    private func emit(_ state: CameraSessionState) {
        guard let onStateChange else { return }
        DispatchQueue.main.async { onStateChange(state) }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Drop frames above our processing cap before doing any work.
        guard frameThrottle.shouldProcess() else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Downscale into an owned buffer NOW, on this (session) queue, while the capture
        // surface is still valid — the consumer processes it asynchronously on another queue.
        let owned = downscaler.downscale(pixelBuffer)
        onFrame?(owned, Self.orientation(for: connection))
    }

    /// Derive the `CGImagePropertyOrientation` Vision should use for this connection.
    ///
    /// For a built-in/front webcam in landscape the buffer is typically `.up`; mirroring
    /// (`isVideoMirrored`) is a horizontal flip that applies uniformly to face *and* hand
    /// points, so it does **not** break the analyzer's relative-position logic and we do
    /// not transform for it. We still derive (rather than hardcode) so external/rotated
    /// cameras are handled correctly.
    private static func orientation(for connection: AVCaptureConnection) -> CGImagePropertyOrientation {
        // macOS capture connections expose rotation via `videoRotationAngle` (macOS 14+);
        // map the common angles to the matching property orientation.
        if #available(macOS 14.0, *) {
            switch connection.videoRotationAngle {
            case 90: return .right
            case 180: return .down
            case 270: return .left
            default: return .up
            }
        }
        return .up
    }
}
