import CoreGraphics
import Foundation

/// Pure value types that flow through the detection engine.
///
/// None of these import Vision or AVFoundation — they are the testable spine of the
/// detector. `VisionFrameAnalyzer` is responsible for translating Vision observations
/// into these neutral shapes; everything downstream (`FaceGeometry`, `ProximityAnalyzer`,
/// `GestureDetector`) operates purely on them. All coordinates are in Vision's
/// **image-normalized** space (origin bottom-left, 0…1 on both axes).

// MARK: - DetectionResult

/// The detector's per-frame verdict, consumed on the main actor by the alerting layer.
///
/// `.mouthContact` means nail-biting (fingertip at the mouth); `.noseContact` means
/// nose-poking. The associated `confidence` is the smoothed region score (0…1) at the
/// moment the gesture was declared, so plan 03 can tailor message/intensity.
enum DetectionResult: Equatable {
    case none
    case mouthContact(confidence: Double)
    case noseContact(confidence: Double)

    /// Whether this result represents an active hand-to-face gesture.
    var isContact: Bool {
        switch self {
        case .none: return false
        case .mouthContact, .noseContact: return true
        }
    }

    /// The region a contact targets, or `.none`.
    var region: Region {
        switch self {
        case .none: return .none
        case .mouthContact: return .mouth
        case .noseContact: return .nose
        }
    }
}

// MARK: - Region

/// Which face sub-region a gesture is targeting.
enum Region: String, Codable, Equatable {
    case none
    case mouth
    case nose
}

// MARK: - Hand & Face landmark inputs

/// A single weighted, confidence-tagged hand landmark in image-normalized space.
struct HandPoint: Codable, Equatable {
    var location: CGPoint
    /// Vision confidence for this joint (0…1).
    var confidence: Float
    /// Triggering weight: fingertips 1.0, secondary DIP joints 0.4, wrist 0.
    var weight: Double

    init(location: CGPoint, confidence: Float, weight: Double) {
        self.location = location
        self.confidence = confidence
        self.weight = weight
    }
}

/// The fingertip-centric view of one detected hand.
struct HandLandmarks: Codable, Equatable {
    /// Weighted joints that participate in proximity scoring (fingertips + DIPs).
    var fingertips: [HandPoint]
    /// Wrist location, used only for posture heuristics (palm/knuckle resting). Optional.
    var wrist: CGPoint?

    init(fingertips: [HandPoint], wrist: CGPoint? = nil) {
        self.fingertips = fingertips
        self.wrist = wrist
    }
}

/// The face landmark regions we care about, in image-normalized space.
///
/// Region point arrays may be empty if a particular constellation region was
/// unavailable; `FaceGeometry` falls back to face-box fractions in that case.
struct FaceLandmarks: Codable, Equatable {
    /// The face bounding box (image-normalized).
    var boundingBox: CGRect
    /// `outerLips` points (mouth target).
    var outerLips: [CGPoint]
    /// `nose` + `noseCrest` points (nose target).
    var nose: [CGPoint]
    /// `medianLine` points (used to derive the lower-jaw chin band).
    var medianLine: [CGPoint]

    init(
        boundingBox: CGRect,
        outerLips: [CGPoint] = [],
        nose: [CGPoint] = [],
        medianLine: [CGPoint] = []
    ) {
        self.boundingBox = boundingBox
        self.outerLips = outerLips
        self.nose = nose
        self.medianLine = medianLine
    }
}

// MARK: - FrameObservation

/// The geometry extracted from a single frame by a `FrameAnalyzing` implementation.
///
/// Decision-free: it carries only what Vision saw. Codable so sessions can be recorded
/// to JSON fixtures and replayed through the real `GestureDetector` in tests.
struct FrameObservation: Codable, Equatable {
    var face: FaceLandmarks?
    var hands: [HandLandmarks]

    init(face: FaceLandmarks? = nil, hands: [HandLandmarks] = []) {
        self.face = face
        self.hands = hands
    }

    /// All weighted fingertips across every detected hand, flattened.
    var allFingertips: [HandPoint] {
        hands.flatMap { $0.fingertips }
    }
}

// MARK: - FrameScore

/// The per-frame soft proximity score produced by `ProximityAnalyzer`, before any
/// temporal smoothing. Fed to `GestureDetector`.
struct FrameScore: Equatable {
    /// Soft proximity to the mouth region, 0…1.
    var mouthScore: Double
    /// Soft proximity to the nose region, 0…1.
    var noseScore: Double

    init(mouthScore: Double = 0, noseScore: Double = 0) {
        self.mouthScore = mouthScore
        self.noseScore = noseScore
    }

    static let zero = FrameScore(mouthScore: 0, noseScore: 0)

    /// The region with the higher raw score (ties → mouth), or `.none` if both are 0.
    var dominant: Region {
        if mouthScore == 0 && noseScore == 0 { return .none }
        return mouthScore >= noseScore ? .mouth : .nose
    }
}
