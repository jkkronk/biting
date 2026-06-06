import Foundation

/// Convenience accessors for bundle metadata, used by the About screen.
enum AppInfo {
    /// Human-facing display name (e.g. "Shoo").
    static var displayName: String {
        bundleString("CFBundleDisplayName")
            ?? bundleString("CFBundleName")
            ?? "Shoo"
    }

    /// Marketing version (`CFBundleShortVersionString`, e.g. "0.1.0").
    static var version: String {
        bundleString("CFBundleShortVersionString") ?? "—"
    }

    /// Build number (`CFBundleVersion`).
    static var build: String {
        bundleString("CFBundleVersion") ?? "—"
    }

    /// Copyright string (`NSHumanReadableCopyright`).
    static var copyright: String {
        bundleString("NSHumanReadableCopyright") ?? ""
    }

    /// Combined "version (build)" string for compact display.
    static var versionDisplay: String {
        "Version \(version) (\(build))"
    }

    private static func bundleString(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return value?.isEmpty == true ? nil : value
    }
}
