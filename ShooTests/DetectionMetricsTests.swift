import XCTest
@testable import Shoo

/// Replays a labeled ``FrameObservation`` corpus through the *real* per-frame scorer and
/// ``GestureDetector`` (the production decision path, minus Vision) and asserts aggregate
/// quality: recall on positive gestures, no false alerts on negatives (chin-rest!), and
/// onset latency within budget. These numbers are the detector's CI regression gate.
final class DetectionMetricsTests: XCTestCase {
    /// Run the corpus through the pipeline at the default sensitivity and collect, per
    /// frame, the emitted `DetectionResult` alongside the ground-truth label.
    private func replay(
        _ fixture: FrameObservationFixture,
        sensitivity: Double = 0.5
    ) -> [(label: LabeledFrame.Label, result: DetectionResult)] {
        let config = DetectorConfig.from(sensitivity: sensitivity)
        let scorer = ProximityAnalyzer(reach: config.reach, chinRestPenalty: config.chinRestPenalty)
        var gesture = GestureDetector(config: config)

        return fixture.frames.map { frame in
            let result: DetectionResult
            if let face = frame.observation.face {
                let geometry = FaceGeometry(landmarks: face, regionPad: config.regionPad)
                let score = scorer.frameScore(geometry: geometry, fingertips: frame.observation.allFingertips)
                result = gesture.ingest(score)
            } else {
                result = gesture.ingest(.zero)
            }
            return (frame.label, result)
        }
    }

    func testFixtureCodableRoundTrip() throws {
        let fixture = SyntheticFixture.corpus()
        let data = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(FrameObservationFixture.self, from: data)
        XCTAssertEqual(decoded, fixture)
    }

    func testRecallOnPositiveGestures() {
        let fixture = SyntheticFixture.corpus()
        let timeline = replay(fixture)

        // Recall is measured per *gesture*: a contiguous run of same-labeled positive
        // frames counts as recalled if the detector fired a matching contact during it
        // (allowing for sustain/EMA ramp-up at the start). This mirrors "did we catch the
        // bite", not "did every single frame fire".
        let gestures = positiveRuns(timeline)
        XCTAssertFalse(gestures.isEmpty)
        let recalled = gestures.filter { run in
            timeline[run.range].contains { $0.result.region == run.region }
        }.count
        let recall = Double(recalled) / Double(gestures.count)
        XCTAssertGreaterThanOrEqual(recall, 0.90, "recall \(recall) below 0.90")
    }

    func testNoFalseAlertsOnNegativeOnlyGestures() {
        let fixture = SyntheticFixture.corpus()
        let timeline = replay(fixture)

        // A "false alert" = a *rising edge* into contact (.none → contact) on a negative
        // frame. Hysteresis tails (a contact decaying across the first negative frames
        // after a real gesture) are expected and not counted. The chin-rest segment is
        // the key adversarial case: knuckles in the chin band must never start a new alert.
        var falseAlerts = 0
        var prev: DetectionResult = .none
        for (label, result) in timeline {
            if label == .negative, !prev.isContact, result.isContact {
                falseAlerts += 1
            }
            prev = result
        }
        XCTAssertEqual(falseAlerts, 0, "negative footage raised \(falseAlerts) false alerts")
    }

    /// Group contiguous same-label positive frames into gesture runs.
    private func positiveRuns(
        _ timeline: [(label: LabeledFrame.Label, result: DetectionResult)]
    ) -> [(range: Range<Int>, region: Region)] {
        var runs: [(Range<Int>, Region)] = []
        var i = 0
        while i < timeline.count {
            let label = timeline[i].label
            guard label != .negative else { i += 1; continue }
            let region: Region = label == .positiveMouth ? .mouth : .nose
            var j = i
            while j < timeline.count, timeline[j].label == label { j += 1 }
            runs.append((i..<j, region))
            i = j
        }
        return runs.map { ($0.0, $0.1) }
    }

    func testCorrectRegionClassification() {
        let fixture = SyntheticFixture.corpus()
        let timeline = replay(fixture)

        // On positive frames, the emitted contact must match the labeled region. (Contacts
        // on negative frames are hysteresis tails of the preceding gesture — same region,
        // not a misclassification — and are exercised by the false-alert test instead.)
        for (label, result) in timeline where result.isContact {
            switch label {
            case .positiveMouth: XCTAssertEqual(result.region, .mouth)
            case .positiveNose: XCTAssertEqual(result.region, .nose)
            case .negative: break  // hysteresis tail; covered by testNoFalseAlertsOnNegativeOnlyGestures
            }
        }
    }

    func testOnsetLatencyWithinBudget() {
        let fixture = SyntheticFixture.corpus()
        let timeline = replay(fixture)

        // Find the first positive-mouth frame and the first contact at/after it.
        guard let onset = timeline.firstIndex(where: { $0.label == .positiveMouth }) else {
            return XCTFail("fixture has no mouth gesture")
        }
        guard let fired = timeline[onset...].firstIndex(where: { $0.result.isContact }) else {
            return XCTFail("mouth gesture never fired")
        }
        let framesToFire = fired - onset
        // ≤6 frames (~600 ms @ 10 fps) including detector sustain at default sensitivity.
        XCTAssertLessThanOrEqual(framesToFire, 6, "onset latency \(framesToFire) frames exceeds budget")
    }

    func testHigherSensitivityFiresNoLater() {
        let fixture = SyntheticFixture.corpus()
        func latency(_ s: Double) -> Int {
            let t = replay(fixture, sensitivity: s)
            let onset = t.firstIndex { $0.label == .positiveMouth }!
            let fired = t[onset...].firstIndex { $0.result.isContact }!
            return fired - onset
        }
        XCTAssertLessThanOrEqual(latency(1.0), latency(0.0))
    }
}
