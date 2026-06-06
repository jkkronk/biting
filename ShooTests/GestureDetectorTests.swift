import XCTest
@testable import Shoo

/// Replays scripted ``FrameScore`` timelines and asserts the emitted ``DetectionResult``
/// timeline: enter/exit hysteresis, sustain delay, EMA smoothing of spikes, region
/// arbitration, and decay to `.none` on signal loss.
final class GestureDetectorTests: XCTestCase {
    /// A deterministic config: α=1 (no smoothing lag) makes sustain/hysteresis easy to reason about.
    private func config(
        enter: Double = 0.6, exit: Double = 0.35,
        sustain: Int = 3, smoothing: Double = 1.0
    ) -> DetectorConfig {
        DetectorConfig(
            reach: 0.1, enterThreshold: enter, exitThreshold: exit,
            regionPad: 0.02, minSustainedFrames: sustain, handPointConfidence: 0.3,
            chinRestPenalty: 0.4, smoothing: smoothing)
    }

    private func feed(_ detector: inout GestureDetector, mouth: Double, noseScore: Double = 0) -> DetectionResult {
        detector.ingest(FrameScore(mouthScore: mouth, noseScore: noseScore))
    }

    func testSustainDelaysGesture() {
        var d = GestureDetector(config: config(sustain: 3))
        XCTAssertEqual(feed(&d, mouth: 0.9), .none)  // frame 1
        XCTAssertEqual(feed(&d, mouth: 0.9), .none)  // frame 2
        XCTAssertEqual(feed(&d, mouth: 0.9), .mouthContact(confidence: 0.9))  // frame 3
    }

    func testHysteresisHoldsThroughDip() {
        var d = GestureDetector(config: config(enter: 0.6, exit: 0.35, sustain: 1))
        XCTAssertEqual(feed(&d, mouth: 0.8), .mouthContact(confidence: 0.8))
        // Dips below enter but stays above exit → still active.
        XCTAssertEqual(feed(&d, mouth: 0.5), .mouthContact(confidence: 0.5))
        // Drops to/below exit → releases.
        XCTAssertEqual(feed(&d, mouth: 0.30), .none)
    }

    func testEMASmoothingKillsSingleFrameSpike() {
        // α=0.5: a single spike of 1.0 from rest only lifts EMA to 0.5, below enter=0.6.
        var d = GestureDetector(config: config(enter: 0.6, sustain: 1, smoothing: 0.5))
        XCTAssertEqual(feed(&d, mouth: 0.0), .none)
        XCTAssertEqual(feed(&d, mouth: 1.0), .none)  // EMA = 0.5 < 0.6, spike absorbed
        XCTAssertEqual(feed(&d, mouth: 0.0), .none)
    }

    func testSustainedSignalCrossesThresholdWithSmoothing() {
        var d = GestureDetector(config: config(enter: 0.6, sustain: 1, smoothing: 0.5))
        // Sustained 1.0: EMA climbs 0.5, 0.75, ... crosses 0.6 on frame 2.
        XCTAssertEqual(feed(&d, mouth: 1.0), .none)              // EMA 0.5
        XCTAssertEqual(feed(&d, mouth: 1.0).isContact, true)    // EMA 0.75 ≥ 0.6
    }

    func testRegionArbitrationPicksDominant() {
        var d = GestureDetector(config: config(sustain: 1))
        let r = feed(&d, mouth: 0.7, noseScore: 0.9)
        XCTAssertEqual(r, .noseContact(confidence: 0.9))
    }

    func testDecaysToNoneOnSignalLoss() {
        var d = GestureDetector(config: config(enter: 0.6, exit: 0.35, sustain: 1, smoothing: 0.5))
        // Drive up to active.
        _ = feed(&d, mouth: 1.0)
        let active = feed(&d, mouth: 1.0)
        XCTAssertTrue(active.isContact)
        // Signal lost: EMA decays 0.5·prev each frame until ≤ exit.
        _ = feed(&d, mouth: 0.0)  // ~0.5
        let r = feed(&d, mouth: 0.0)  // ~0.25 ≤ 0.35 → none (or already none)
        XCTAssertEqual(r, .none)
    }

    func testZeroScoreNeverTriggers() {
        var d = GestureDetector(config: config(sustain: 1))
        for _ in 0..<10 { XCTAssertEqual(feed(&d, mouth: 0.0), .none) }
    }

    func testResetClearsState() {
        var d = GestureDetector(config: config(sustain: 1))
        _ = feed(&d, mouth: 0.9)
        XCTAssertTrue(d.active.isContact)
        d.reset()
        XCTAssertEqual(d.active, .none)
        // After reset, a single high frame with sustain=1 re-triggers cleanly.
        XCTAssertTrue(feed(&d, mouth: 0.9).isContact)
    }

    func testSwitchesRegionWhenNoseBecomesDominant() {
        var d = GestureDetector(config: config(enter: 0.6, exit: 0.35, sustain: 1))
        XCTAssertEqual(feed(&d, mouth: 0.9, noseScore: 0.0), .mouthContact(confidence: 0.9))
        // Mouth drops below exit while nose rises and qualifies → switch.
        XCTAssertEqual(feed(&d, mouth: 0.2, noseScore: 0.9), .noseContact(confidence: 0.9))
    }
}
