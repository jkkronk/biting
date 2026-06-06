import os

/// Centralized `os.Logger` instances, one per subsystem area.
/// Use like `AppLogger.camera.error("…")`.
enum AppLogger {
    private static let subsystem = "com.shoo.Shoo"

    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let detection = Logger(subsystem: subsystem, category: "detection")
    static let alerting = Logger(subsystem: subsystem, category: "alerting")
    static let app = Logger(subsystem: subsystem, category: "app")
}
