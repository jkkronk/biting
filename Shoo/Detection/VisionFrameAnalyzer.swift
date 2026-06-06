import CoreVideo
import Foundation
import ImageIO
import Vision

/// Seam over the frame→geometry extraction step. Production uses ``VisionFrameAnalyzer``;
/// tests inject a mock returning scripted ``FrameObservation``s, so the coordinator's
/// throttle/mailbox/config logic is testable without a camera.
protocol FrameAnalyzing: AnyObject {
    /// Pure extraction: run Vision (or return canned data) and yield geometry only — no
    /// decision making.
    func analyze(_ pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation) -> FrameObservation
}

/// Runs the two on-device Vision requests (face landmarks + hand pose) for one frame and
/// translates the observations into the neutral ``FrameObservation`` shape.
///
/// Stays on the classic `VN*` request API (the Swift-native async surface is macOS 15+;
/// our floor is macOS 14). Requests are reused so the models load once; revisions are
/// pinned for reproducible behavior across OS updates.
final class VisionFrameAnalyzer: FrameAnalyzing {
    private let faceRequest: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        // 76-point constellation gives richer mouth/nose traces + per-point precision.
        request.constellation = .constellation76Points
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()

    private let handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        request.revision = VNDetectHumanHandPoseRequestRevision1
        return request
    }()

    /// Confidence floor for hand joints; updated from `DetectorConfig` by the coordinator.
    var handPointConfidence: Float = 0.3

    /// Primary fingertips (weight 1.0) and secondary DIP joints (weight 0.4).
    private static let primaryTips: [(VNHumanHandPoseObservation.JointName, Double)] = [
        (.thumbTip, 1.0), (.indexTip, 1.0), (.middleTip, 1.0),
        (.ringTip, 1.0), (.littleTip, 1.0),
    ]
    private static let secondaryJoints: [(VNHumanHandPoseObservation.JointName, Double)] = [
        (.indexDIP, 0.4), (.middleDIP, 0.4),
    ]

    func analyze(_ pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation) -> FrameObservation {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([faceRequest, handRequest])
        } catch {
            AppLogger.detection.error("Vision perform failed: \(error.localizedDescription, privacy: .public)")
            return FrameObservation()
        }
        return FrameObservation(face: extractFace(), hands: extractHands())
    }

    // MARK: - Face

    /// Largest detected face, translated to image-normalized landmark regions.
    private func extractFace() -> FaceLandmarks? {
        let faces = faceRequest.results ?? []
        guard let face = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }

        let box = face.boundingBox
        let landmarks = face.landmarks
        return FaceLandmarks(
            boundingBox: box,
            outerLips: imageNormalizedPoints(landmarks?.outerLips, in: box),
            nose: imageNormalizedPoints(landmarks?.nose, in: box)
                + imageNormalizedPoints(landmarks?.noseCrest, in: box),
            medianLine: imageNormalizedPoints(landmarks?.medianLine, in: box))
    }

    /// Convert a face-box-normalized region's points to image-normalized space.
    private func imageNormalizedPoints(_ region: VNFaceLandmarkRegion2D?, in box: CGRect) -> [CGPoint] {
        guard let region else { return [] }
        return region.normalizedPoints.map { FaceGeometry.imageNormalized($0, in: box) }
    }

    // MARK: - Hands

    private func extractHands() -> [HandLandmarks] {
        var hands: [HandLandmarks] = []
        for observation in handRequest.results ?? [] {
            guard let recognized = try? observation.recognizedPoints(.all) else { continue }
            var tips: [HandPoint] = []
            for (joint, weight) in Self.primaryTips + Self.secondaryJoints {
                guard let point = recognized[joint], point.confidence > handPointConfidence else { continue }
                tips.append(HandPoint(location: point.location, confidence: point.confidence, weight: weight))
            }
            // Wrist (weight 0): posture only, not triggering.
            let wrist = recognized[.wrist].flatMap { $0.confidence > handPointConfidence ? $0.location : nil }
            if !tips.isEmpty || wrist != nil {
                hands.append(HandLandmarks(fingertips: tips, wrist: wrist))
            }
        }
        return hands
    }
}
