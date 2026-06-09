import AVFoundation

/// Builds an `AVCaptureDevice.DiscoverySession` and ranks the available cameras so
/// ``CameraController`` always picks a sensible default and survives hot-swaps.
///
/// Ranking preference:
///  1. A remembered device whose `uniqueID` is still present.
///  2. The system default (`AVCaptureDevice.default(for: .video)`), if discovered.
///  3. The first built-in wide-angle camera.
///  4. The first available device.
/// `.deskViewCamera` (overhead desk view — wrong framing) is skipped unless it is the
/// only device available.
enum DeviceSelector {
    /// `UserDefaults` key holding the chosen device `uniqueID`.
    static let storedDeviceIDKey = "cameraDeviceID"

    /// The camera device types we are willing to use, guarding cases that may be
    /// unavailable on older toolchains/hardware.
    static var discoveryDeviceTypes: [AVCaptureDevice.DeviceType] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) {
            types.append(.continuityCamera)
            types.append(.deskViewCamera)
        }
        return types
    }

    /// All currently-discoverable video devices.
    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryDeviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Lightweight descriptor so the ranking core is unit-testable — `AVCaptureDevice`
    /// cannot be constructed in tests.
    struct CameraDescriptor: Equatable {
        let uniqueID: String
        let isDeskView: Bool
        let isBuiltInWideAngle: Bool
    }

    /// Pure ranking core implementing the preference order documented above.
    static func rank(
        preferredID: String?,
        systemDefaultID: String?,
        devices: [CameraDescriptor]
    ) -> CameraDescriptor? {
        guard !devices.isEmpty else { return nil }

        // Prefer non-deskView devices for face/hand framing.
        let usable = devices.filter { !$0.isDeskView }
        let pool = usable.isEmpty ? devices : usable

        // 1. Remembered device, if still present.
        if let preferredID, let match = pool.first(where: { $0.uniqueID == preferredID }) {
            return match
        }

        // 2. System default, if it's in our usable pool.
        if let systemDefaultID,
           let system = pool.first(where: { $0.uniqueID == systemDefaultID }) {
            return system
        }

        // 3. First built-in wide-angle camera.
        if let builtIn = pool.first(where: { $0.isBuiltInWideAngle }) {
            return builtIn
        }

        // 4. First available.
        return pool.first
    }

    /// Picks the best device, honoring a stored preferred `uniqueID` if present.
    /// Returns `nil` when no usable camera exists. Thin AVFoundation shim over ``rank``.
    static func selectDevice(
        preferredID: String? = UserDefaults.standard.string(forKey: storedDeviceIDKey),
        devices: [AVCaptureDevice] = availableDevices()
    ) -> AVCaptureDevice? {
        let descriptors = devices.map {
            CameraDescriptor(
                uniqueID: $0.uniqueID,
                isDeskView: isDeskView($0),
                isBuiltInWideAngle: $0.deviceType == .builtInWideAngleCamera)
        }
        let chosen = rank(
            preferredID: preferredID,
            systemDefaultID: AVCaptureDevice.default(for: .video)?.uniqueID,
            devices: descriptors)
        return chosen.flatMap { pick in devices.first { $0.uniqueID == pick.uniqueID } }
    }

    private static func isDeskView(_ device: AVCaptureDevice) -> Bool {
        if #available(macOS 14.0, *) {
            return device.deviceType == .deskViewCamera
        }
        return false
    }
}
