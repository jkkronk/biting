import AppKit
import CoreImage
import CoreVideo
import ImageIO

/// Converts a camera `CVPixelBuffer` into an `NSImage` for the reminder overlay.
///
/// Runs at most once per alert (gated by the alert cooldown), so a shared `CIContext` is
/// reused rather than rebuilt each call. The image is mirrored horizontally so it reads like
/// a mirror/selfie. Nothing here persists the frame — the result lives only as long as the
/// overlay shows it.
enum CameraSnapshot {
    /// Shared GPU-backed context; creating one per call is wasteful.
    private static let context = CIContext()

    /// Render `buffer` (BGRA) into a mirrored `NSImage`, applying the capture orientation.
    /// Returns `nil` if the pixel buffer can't be rendered.
    static func image(
        from buffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> NSImage? {
        let oriented = CIImage(cvPixelBuffer: buffer)
            .oriented(orientation)
        // Mirror across the vertical axis for a natural selfie view.
        let mirrored = oriented.transformed(
            by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -oriented.extent.width, y: 0)
        )
        guard let cgImage = context.createCGImage(mirrored, from: mirrored.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
