import AppKit

/// Plays a short named system sound for an alert, falling back to the system beep when the
/// requested name can't be resolved. Sandbox-safe: only named system sounds, never paths.
@MainActor
final class SoundPlayer {
    /// Keep the playing sound retained so it isn't deallocated mid-playback.
    private var current: NSSound?

    /// Play the named system sound (e.g. `"Pop"`), or `NSSound.beep()` if it's invalid.
    func play(named name: String) {
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.stop()  // restart if already playing for a rapid re-fire
            current = sound
            sound.play()
        } else {
            AppLogger.alerting.error("Unknown sound name \(name, privacy: .public); using beep")
            NSSound.beep()
        }
    }
}
