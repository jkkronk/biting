import CoreVideo
import XCTest
@testable import Shoo

/// `FrameDownscaler` must ALWAYS return a pool-owned buffer (never the capture-owned source),
/// because the result is handed to another queue after the capture delegate returns.
final class FrameDownscalerTests: XCTestCase {
    func testShrinksOversizeFrameToLongestEdge() {
        let downscaler = FrameDownscaler(longestEdge: 128)
        let src = MockFrameSource.makePixelBuffer(width: 640, height: 480)

        let out = downscaler.downscale(src)

        // Longest edge clamped to 128; aspect ratio preserved (640:480 → 128:96).
        XCTAssertEqual(CVPixelBufferGetWidth(out), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 96)
        XCTAssertFalse(out === src, "must not pass the source buffer through")
    }

    func testAlreadySmallFrameIsCopiedNotPassedThrough() {
        let downscaler = FrameDownscaler(longestEdge: 512)
        let src = MockFrameSource.makePixelBuffer(width: 64, height: 64)

        let out = downscaler.downscale(src)

        // Same dimensions (1:1 copy) but a distinct, owned buffer.
        XCTAssertEqual(CVPixelBufferGetWidth(out), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 64)
        XCTAssertFalse(out === src, "already-small frames must be copied, not passed through")
    }

    func testOutputIsBGRA() {
        let downscaler = FrameDownscaler(longestEdge: 128)
        let out = downscaler.downscale(MockFrameSource.makePixelBuffer(width: 320, height: 240))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_32BGRA)
    }
}
