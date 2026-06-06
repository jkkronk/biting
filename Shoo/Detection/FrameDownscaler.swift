import CoreImage
import CoreVideo
import Foundation

/// Downscales a captured `CVPixelBuffer` to a small working buffer before Vision sees it.
///
/// Vision does not need 720p+ to find a face/hands at desk distance; shrinking to a
/// ~512 px longest edge cuts ANE/GPU cost substantially. Uses a single Metal-backed
/// `CIContext` and a recycled `CVPixelBufferPool` to avoid per-frame allocation.
///
/// Vision-adjacent (imports CoreImage/CoreVideo) so it lives outside the pure logic core.
final class FrameDownscaler {
    private let context: CIContext
    private let longestEdge: CGFloat

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    init(longestEdge: CGFloat = 512) {
        self.longestEdge = longestEdge
        // GPU renderer; reuse one context (creating per-frame is expensive).
        self.context = CIContext(options: [.useSoftwareRenderer: false])
    }

    /// Return a downscaled BGRA buffer, or the original if it's already small enough or
    /// scaling fails (degrade rather than drop the frame).
    func downscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let maxEdge = CGFloat(max(srcW, srcH))
        guard maxEdge > longestEdge else { return pixelBuffer }

        let scale = longestEdge / maxEdge
        let dstW = max(1, Int((CGFloat(srcW) * scale).rounded()))
        let dstH = max(1, Int((CGFloat(srcH) * scale).rounded()))

        guard let output = makeOutputBuffer(width: dstW, height: dstH) else {
            return pixelBuffer
        }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(scaled, to: output)
        return output
    }

    // MARK: - Pool management

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            rebuildPool(width: width, height: height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess else {
            return nil
        }
        return out
    }

    private func rebuildPool(width: Int, height: Int) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
        pool = newPool
        poolWidth = width
        poolHeight = height
    }
}
