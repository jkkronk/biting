import CoreVideo
import Foundation
import ImageIO

/// Coordinates the detection pipeline on a serial queue: analyze (Vision) → per-frame score
/// (``ProximityAnalyzer`` over ``FaceGeometry``) → temporal model (``GestureDetector``) →
/// ``DetectionResult``.
///
/// Frames arrive **already downscaled and owned** (the capture layer runs ``FrameDownscaler``
/// synchronously on the capture queue, where the source buffer is valid). This type is just
/// the threading + coalescing glue. All detector state (`gesture`, `config`) is touched
/// **only** on `detectionQueue`; config swaps hop onto that queue so nothing is mutated
/// cross-thread.
final class HandFaceDetector {
    private let analyzer: FrameAnalyzing
    private let proximity = ProximityAnalyzer()
    private let detectionQueue = DispatchQueue(label: "com.shoo.detection", qos: .userInitiated)

    // detectionQueue-only state ----------------------------------------------
    private var gesture: GestureDetector
    private var config: DetectorConfig
    private var proximityScorer: ProximityAnalyzer
    /// Single-slot mailbox: only the newest pending frame is kept while one is in flight,
    /// so we never queue up a backlog under load.
    private var pendingFrame: (buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)?
    private var isProcessing = false
    // ------------------------------------------------------------------------

    /// Injection point so tests can drive a `MockFrameAnalyzer`.
    init(analyzer: FrameAnalyzing = VisionFrameAnalyzer(),
         config: DetectorConfig = .default) {
        self.analyzer = analyzer
        self.config = config
        self.gesture = GestureDetector(config: config)
        self.proximityScorer = ProximityAnalyzer(reach: config.reach, chinRestPenalty: config.chinRestPenalty)
        applyConfigToAnalyzer(config)
    }

    /// Swap the sensitivity-derived tunables. Hops onto the detection queue so detector
    /// state isn't mutated cross-thread.
    func updateConfig(_ newConfig: DetectorConfig) {
        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.config = newConfig
            self.gesture.config = newConfig
            self.proximityScorer = ProximityAnalyzer(
                reach: newConfig.reach, chinRestPenalty: newConfig.chinRestPenalty)
            self.applyConfigToAnalyzer(newConfig)
        }
    }

    /// Reset temporal state (e.g. when watching stops). Hops onto the detection queue.
    func reset() {
        detectionQueue.async { [weak self] in
            self?.gesture.reset()
            self?.pendingFrame = nil
        }
    }

    /// Ingest one frame. Coalesces to a single-slot mailbox; `completion` is called on the
    /// detection queue with the latest ``DetectionResult`` for each frame actually processed.
    func process(_ pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation,
                 completion: @escaping (DetectionResult) -> Void) {
        detectionQueue.async { [weak self] in
            guard let self else { return }
            // Keep only the newest pending frame; process immediately if idle.
            self.pendingFrame = (pixelBuffer, orientation)
            guard !self.isProcessing else { return }
            self.drainMailbox(completion: completion)
        }
    }

    // MARK: - Pipeline (detectionQueue only)

    private func drainMailbox(completion: @escaping (DetectionResult) -> Void) {
        guard let (buffer, orientation) = pendingFrame else { return }
        pendingFrame = nil
        isProcessing = true

        let result = runPipeline(buffer, orientation: orientation)
        completion(result)

        isProcessing = false
        // If a newer frame arrived while we were busy, process it now.
        if pendingFrame != nil {
            drainMailbox(completion: completion)
        }
    }

    private func runPipeline(_ pixelBuffer: CVPixelBuffer,
                             orientation: CGImagePropertyOrientation) -> DetectionResult {
        // The buffer is already downscaled & owned by the capture layer.
        let observation = analyzer.analyze(pixelBuffer, orientation: orientation)

        // No face → no contact; decay the temporal model toward zero.
        guard let face = observation.face else {
            return gesture.ingest(.zero)
        }
        let geometry = FaceGeometry(landmarks: face, regionPad: config.regionPad)
        let frameScore = proximityScorer.frameScore(
            geometry: geometry, fingertips: observation.allFingertips)
        // Suppress regions the user isn't watching so a disabled gesture can't arm.
        let masked = frameScore.masked(mouthEnabled: config.mouthEnabled, noseEnabled: config.noseEnabled)
        return gesture.ingest(masked)
    }

    private func applyConfigToAnalyzer(_ config: DetectorConfig) {
        // Push the hand-confidence floor into the Vision analyzer when applicable.
        (analyzer as? VisionFrameAnalyzer)?.handPointConfidence = config.handPointConfidence
    }
}
