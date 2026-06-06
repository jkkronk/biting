import CoreGraphics
import Foundation
@testable import Shoo

/// A labeled, replayable sequence of ``FrameObservation``s used by the metrics harness.
///
/// `FrameObservation` is already `Codable`, so a fixture is just an array of frames each
/// tagged with the ground-truth label. A debug-build recorder (not shipped) can dump live
/// observations to disk in this shape to grow the corpus; here we synthesize representative
/// fixtures programmatically so CI has deterministic numbers to gate on.
struct LabeledFrame: Codable, Equatable {
    enum Label: String, Codable {
        case positiveMouth
        case positiveNose
        case negative
    }
    var label: Label
    var observation: FrameObservation
}

struct FrameObservationFixture: Codable, Equatable {
    var name: String
    var frames: [LabeledFrame]
}

// MARK: - Synthetic fixture builders

/// Deterministic geometry shared across synthetic fixtures: a centered face whose mouth
/// and nose boxes are known, so we can place fingertips precisely on/off target.
enum SyntheticFixture {
    static let faceBox = CGRect(x: 0.35, y: 0.30, width: 0.30, height: 0.40)

    static var face: FaceLandmarks {
        FaceLandmarks(
            boundingBox: faceBox,
            outerLips: [CGPoint(x: 0.46, y: 0.42), CGPoint(x: 0.54, y: 0.45)],
            nose: [CGPoint(x: 0.47, y: 0.54), CGPoint(x: 0.53, y: 0.58)],
            medianLine: [CGPoint(x: 0.50, y: 0.40), CGPoint(x: 0.50, y: 0.38)])
    }

    static var mouthCenter: CGPoint {
        let g = FaceGeometry(landmarks: face, regionPad: 0.03)
        return CGPoint(x: g.mouthBox.midX, y: g.mouthBox.midY)
    }

    static var noseCenter: CGPoint {
        let g = FaceGeometry(landmarks: face, regionPad: 0.03)
        return CGPoint(x: g.noseBox.midX, y: g.noseBox.midY)
    }

    /// A frame with a single fingertip at `tip` (high confidence) plus a face.
    static func frame(tip: CGPoint, confidence: Float = 0.9, label: LabeledFrame.Label) -> LabeledFrame {
        let hand = HandLandmarks(
            fingertips: [HandPoint(location: tip, confidence: confidence, weight: 1.0)],
            wrist: CGPoint(x: tip.x, y: tip.y - 0.2))
        return LabeledFrame(label: label, observation: FrameObservation(face: face, hands: [hand]))
    }

    /// A "no hands, face only" negative frame (e.g. just sitting there).
    static func emptyFrame() -> LabeledFrame {
        LabeledFrame(label: .negative, observation: FrameObservation(face: face, hands: []))
    }

    /// Build a corpus: a stretch of desk-work negatives, a sustained mouth bite, more
    /// negatives, a chin-rest (knuckles below the mouth — must NOT register), then a
    /// sustained nose poke. Returns the fixture plus the frame index where each positive
    /// gesture *starts* (for latency assertions).
    static func corpus() -> FrameObservationFixture {
        var frames: [LabeledFrame] = []

        // 30 negative desk-work frames (hand low / away).
        for _ in 0..<30 {
            frames.append(frame(tip: CGPoint(x: 0.20, y: 0.20), label: .negative))
        }

        // Sustained mouth bite: 12 frames with a fingertip in the mouth box.
        let mouthOnset = frames.count
        for _ in 0..<12 {
            frames.append(frame(tip: mouthCenter, label: .positiveMouth))
        }
        _ = mouthOnset

        // Release: 20 negatives.
        for _ in 0..<20 {
            frames.append(emptyFrame())
        }

        // Chin-rest: 15 frames with knuckles in the chin band (below mouth), low weight
        // fingertips — these are labeled negative and must not trigger.
        let g = FaceGeometry(landmarks: face, regionPad: 0.03)
        let chinPoint = CGPoint(x: g.chinBand.midX, y: g.chinBand.midY)
        for _ in 0..<15 {
            // Knuckle resting: a DIP-weight (0.4) point in the chin band, not the mouth.
            let hand = HandLandmarks(
                fingertips: [HandPoint(location: chinPoint, confidence: 0.9, weight: 0.4)],
                wrist: CGPoint(x: chinPoint.x, y: chinPoint.y - 0.2))
            frames.append(LabeledFrame(label: .negative,
                                       observation: FrameObservation(face: face, hands: [hand])))
        }

        // Sustained nose poke: 12 frames.
        for _ in 0..<12 {
            frames.append(frame(tip: noseCenter, label: .positiveNose))
        }

        // Tail negatives.
        for _ in 0..<10 {
            frames.append(emptyFrame())
        }

        return FrameObservationFixture(name: "synthetic-desk-session", frames: frames)
    }
}
