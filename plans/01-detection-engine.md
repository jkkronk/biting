# 01 — Detection Engine

## Context

Shoo's entire value proposition lives in one question, asked ~10 times a second: *"is the user bringing a hand to their face right now?"* Every other subsystem (camera, alerting, overlay, settings) exists only to serve, throttle, or react to the answer. If the detector is wrong, the app is either useless (misses real nail-biting / nose-poking) or actively hostile (fires the "Stop!" overlay while the user is just thinking with a hand on their chin). This document specifies the production-grade detector that replaces today's stub.

The problem is genuinely subtle:

- **Two distinct target gestures.** Nail-biting happens at the **mouth**; nose-poking happens at the **nose**. A plain face *bounding box* cannot tell them apart, and — more importantly — cannot distinguish "fingers at the mouth" (bite) from "knuckles resting on the cheek/chin" (benign). We need **sub-regions of the face**, not just the box.
- **Front-camera geometry.** Vision uses a normalized, bottom-left-origin coordinate space; the built-in webcam feed is mirrored; the pixel buffer carries an orientation. Getting hand points and the face box into the *same* space is the difference between a working detector and noise.
- **Temporal nature.** A single frame is a weak signal (Vision jitters, hands occlude themselves). The real signal is *sustained* proximity over several frames, with hysteresis so we don't flicker on the boundary.
- **Always-on cost.** This runs for hours on battery. The pipeline must be cheap: throttled frame rate, downscaled buffers, Neural-Engine-backed requests, late-frame dropping, and graceful thermal behavior.

### Current stub state (file refs)

The pipeline is fully wired but the *decision* is naive:

- `Shoo/Detection/HandFaceDetector.swift` — runs `VNDetectFaceRectanglesRequest` + `VNDetectHumanHandPoseRequest` per frame on `com.shoo.detection`, takes the **largest face box only**, and flattens **all** hand joints with `confidence > 0.3` into a `[CGPoint]` (see the `TODO` on line 55 — fingertips are not yet selected). No landmarks, no orientation handling (hardcoded `.up`, line 24), no throttling, no downscaling.
- `Shoo/Detection/ProximityAnalyzer.swift` — pure value type. `isHandInFace(face:handPoints:)` expands the face box by `margin` and returns `true` when `>= minPointsInside` points fall inside. The `TODO` on lines 37–38 calls out the missing fingertip weighting, temporal smoothing, and "resting chin on hand" discrimination.
- `Shoo/Camera/CameraManager.swift` — delivers every frame at full preset resolution (`.medium`) on `com.shoo.camera.session`; `TODO` line 67 notes throttling is missing.
- `Shoo/App/AppState.swift` — `wirePipeline()` (lines 51–65) connects `camera.onFrame → detector.process → alerts.handleDetection` on the main actor.
- `Shoo/Alerting/AlertManager.swift` — already debounces (`requiredSustainedHits = 3`) and applies a cooldown, so the detector should emit a *clean per-frame boolean-ish signal*; the manager handles the user-facing event shaping.
- `ShooTests/ProximityAnalyzerTests.swift` — 5 passing tests covering the current box-expansion logic; these must keep passing (or be migrated deliberately).

### API floor decision (researched)

Target is **macOS 14+**. The Swift-native, async Vision API (`DetectHumanHandPoseRequest`, `DetectFaceLandmarksRequest`, the `perform(...)` async surface introduced at WWDC24) is **macOS 15+ only**. Therefore the engine stays on the **classic `VN*` request API** (`VNDetectHumanHandPoseRequest`, `VNDetectFaceLandmarksRequest`, available since macOS 11), which is exactly what the stub already uses. We will isolate Vision behind a protocol so a macOS-15 `@available` fast path can be added later without touching the analyzer. **No new dependency, no model bundle** — both requests are built into Vision and run on the Neural Engine.

## Goals / Definition of done

A detection engine is "done" when all of the following hold:

**Functional**
- Distinguishes **two gesture classes** — `mouthContact` (nail-biting) and `noseContact` (nose-poking) — plus `none`, by targeting the **mouth** and **nose** face landmark regions, not just the bounding box.
- Rejects the canonical false positive: **resting chin/cheek on hand** (palm/knuckles near the lower face with no *fingertip* at mouth or nose) does **not** trigger.
- Emits a stable, temporally-smoothed signal with hysteresis (enter vs. exit thresholds differ) so the boundary doesn't flicker.
- Sensitivity setting (`0…1`) maps monotonically to detection eagerness with sensible end-stops.

**Accuracy targets** (measured on the fixture corpus, see Testing)
- **Recall ≥ 0.90** on labeled positive clips (hand actually at mouth/nose).
- **False-positive rate ≤ 1 spurious alert per 30 min** of "normal desk work" footage (typing, reading, scratching head, chin-resting, drinking).
- **Latency to alert ≤ 600 ms** from gesture onset (≈6 frames @ 10 fps including the 3-frame debounce in `AlertManager`).

**Performance targets** (always-on, on Apple silicon laptop, single external/built-in webcam)
- Vision pipeline processes at the **throttled 10–12 fps** cap, never the camera's native rate.
- **Sustained CPU ≤ 8%** of one P-core (measured via `Instruments` Time Profiler / `powermetrics`) while watching with no face/hands changing.
- **No main-thread Vision work**; main thread only receives the final enum on `@MainActor`.
- Late frames dropped (no queue backlog); no unbounded memory growth over a 1-hour run.
- Detector self-downscales the working buffer; never hands Vision a full-res 720p+ buffer.

**Engineering**
- `ProximityAnalyzer` (and the new temporal/gesture logic it grows into) stays **pure** — no Vision/AVFoundation imports — and is covered by fixture-based unit tests with recorded landmark data.
- Vision access sits behind a protocol (`FrameAnalyzing`) so the engine is unit-testable with synthetic observations.

## Current state

| File | What it does today | What's stubbed / missing |
|---|---|---|
| `Shoo/Detection/HandFaceDetector.swift` | Runs `VNDetectFaceRectanglesRequest` + `VNDetectHumanHandPoseRequest` on `com.shoo.detection`; picks largest face box; flattens all hand joints `>0.3` confidence. | Face **landmarks** (mouth/nose) not requested; fingertips not isolated (TODO L55); orientation hardcoded `.up` (L24, ignores mirroring); no throttle/downscale; no gesture classification; emits bare `Bool`. |
| `Shoo/Detection/ProximityAnalyzer.swift` | Pure box-inset overlap → `Bool`. `margin`, `minPointsInside`. | No fingertip weighting, no temporal smoothing/hysteresis, no chin-rest rejection, no per-region (mouth vs nose) logic, no confidence-aware distance metric (TODO L37–38). |
| `Shoo/Camera/CameraManager.swift` | Full-rate `CVPixelBuffer` delivery, `.medium` preset, `alwaysDiscardsLateVideoFrames = true`. | No fps throttle (TODO L67); no pixel-format pinning; orientation/mirroring not surfaced to detector. |
| `Shoo/App/AppState.swift` | Wires frames → detector → alerts on main actor. | Passes a `Bool`; will need to pass the richer detection result and update the analyzer's tunables when `settings.sensitivity` changes. |
| `Shoo/Alerting/AlertManager.swift` | Debounce (3 sustained) + cooldown. | Fine as-is, but should consume the richer result and can drop its own debounce once the analyzer smooths temporally (kept as a second safety net). |
| `Shoo/Models/AppSettings.swift` | `sensitivity` (0…1, default 0.5) persisted; comment says it maps to `ProximityAnalyzer.margin`. | Mapping not implemented; nothing currently pushes `sensitivity` into the detector. |
| `ShooTests/ProximityAnalyzerTests.swift` | 5 tests on box expansion. | No fixtures, no gesture/temporal tests. |

## Design

### 0. Module shape (overview)

```
CameraManager ──CVPixelBuffer + VNImageRequestOrientation──▶ FrameThrottle
                                                                  │ (≤12 fps, drop late)
                                                                  ▼
                                                          VisionFrameAnalyzer  ──conforms FrameAnalyzing
                                                          (downscale + 2 VN requests)
                                                                  │ FrameObservation
                                                                  ▼
                                                          GestureDetector  (stateful, owns temporal model)
                                                                  │  uses
                                                                  ├──▶ FaceGeometry (mouth/nose region extraction, pure)
                                                                  └──▶ ProximityAnalyzer (per-frame score, pure)
                                                                  │ DetectionResult (enum + confidence)
                                                                  ▼  @MainActor
                                                              AppState ──▶ AlertManager
```

New pure types: `FaceGeometry`, `GestureDetector` (logic core), `HandLandmarks`, `FaceLandmarks`, `DetectionResult`. Vision-touching type: `VisionFrameAnalyzer` (behind `FrameAnalyzing`). `HandFaceDetector` becomes a thin coordinator.

### 1. Vision pipeline

Two requests per (throttled) frame, performed together in one `VNImageRequestHandler`:

```swift
// Face: switch from rectangles to LANDMARKS so we get mouth & nose regions.
let faceRequest: VNDetectFaceLandmarksRequest = {
    let r = VNDetectFaceLandmarksRequest()
    // 76-point constellation gives richer mouth/nose traces + per-point precision.
    r.constellation = .constellation76Points          // macOS 11+
    return r
}()

let handRequest: VNDetectHumanHandPoseRequest = {
    let r = VNDetectHumanHandPoseRequest()
    r.maximumHandCount = 2                              // both hands; cap cost
    return r
}()
```

**Why landmarks over rectangles:** `VNDetectFaceRectanglesRequest` returns only a box — insufficient to tell mouth-contact from nose-contact, and insufficient to reject chin-resting. `VNDetectFaceLandmarksRequest` returns a `VNFaceObservation` whose `landmarks` (`VNFaceLandmarks2D`) expose region sub-groups we need:
- `outerLips` / `innerLips` → **mouth target**
- `nose` / `noseCrest` → **nose target**
- `faceContour`, `medianLine` → for the chin region (used to *exclude* chin-rest)

Landmark points come as `VNFaceLandmarkRegion2D` in **normalized-to-the-face-box** coordinates; convert to image-normalized via `region.pointsInImage(imageSize:)` **or** manual affine using the observation's `boundingBox` (see §2). Cost is modestly higher than rectangles but still ANE-bound and well within budget at ≤12 fps.

**Hand request** stays `VNDetectHumanHandPoseRequest` (21 joints/hand). `maximumHandCount = 2`. We do **not** need `VNDetectHumanBodyPoseRequest`.

**Revision pinning:** pin both requests to a known revision for reproducible behavior across OS updates, guarded by availability:

```swift
if #available(macOS 14.0, *) {
    handRequest.revision = VNDetectHumanHandPoseRequestRevision1
    faceRequest.revision = VNDetectFaceLandmarksRequestRevision3
}
```

**`FrameAnalyzing` seam** (for testability):

```swift
protocol FrameAnalyzing {
    /// Pure extraction: runs Vision (or returns canned data in tests) and yields
    /// geometry only — no decision making.
    func analyze(_ pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation) -> FrameObservation
}

struct FrameObservation {
    var face: FaceLandmarks?          // nil if no face
    var hands: [HandLandmarks]        // 0…2
}
```

### 2. Coordinate spaces, orientation & mirroring

This is the highest-risk area; spell it out.

- **Vision normalized space:** origin **bottom-left**, `(0,0)`→`(1,1)`, y **up**. Both `VNFaceObservation.boundingBox` and hand `recognizedPoint.location` live here, **so they are already comparable** — the analyzer works entirely in this space and never needs pixel coords.
- **Face landmark region points** are normalized **relative to the face bounding box**. Convert to image-normalized once, in `FaceGeometry`:

  ```swift
  // p is a VNFaceLandmarkRegion2D normalizedPoint (0…1 within the face box)
  func imageNormalized(_ p: CGPoint, in box: CGRect) -> CGPoint {
      CGPoint(x: box.minX + p.x * box.width,
              y: box.minY + p.y * box.height)
  }
  ```
  (Equivalently, `region.pointsInImage(imageSize:)` then divide by size — but staying normalized avoids a size round-trip.)

- **Orientation:** the camera buffer is **not** always `.up`. `CameraManager` must compute the correct `CGImagePropertyOrientation` from the `AVCaptureConnection` and pass it through to the handler instead of the hardcoded `.up` (HandFaceDetector L24). For a front/built-in webcam in landscape the buffer is typically `.up`, but we must not assume it — derive it and propagate.

- **Mirroring (front camera):** built-in webcams deliver a **mirrored** image (`connection.isVideoMirrored`). Two consequences:
  1. **Detection correctness:** mirroring is a horizontal flip; because we only compare *relative* positions of hand points vs. face regions in the **same** image, the flip applies uniformly and does **not** break overlap logic. So for *detection*, mirroring is safe to ignore.
  2. **Left/right hand labels & chirality:** `VNHumanHandPoseObservation.chirality` (`.left`/`.right`) is reported in *image* space; under mirroring it's swapped relative to the user. We don't depend on chirality for the trigger, so this is a non-issue for v1 — note it so we don't accidentally rely on it later.

  We therefore **read** mirroring state for completeness/logging but do not transform points for the analyzer. (The overlay in plan 03 lives in screen space and is independent.)

### 3. Which landmarks matter

**Hand — fingertips dominate.** A bite/poke is a *fingertip* event. From each `VNHumanHandPoseObservation` we extract the named joints and weight them:

```swift
enum HandJoint { case thumbTip, indexTip, middleTip, ringTip, littleTip
                 case indexDIP, middleDIP                      // secondary
                 case wrist }                                  // for palm/orientation only
```

Mapped to `VNHumanHandPoseObservation.JointName`: `.thumbTip`, `.indexTip`, `.middleTip`, `.ringTip`, `.littleTip` (primary, weight 1.0); `.indexDIP`, `.middleDIP` (secondary, weight 0.4 — catches a curled finger about to bite); `.wrist` (weight 0 for triggering, used only to estimate hand *reach* direction and to detect "palm-toward-face / knuckles-resting" posture). Use `try observation.recognizedPoints(.all)` once, then select by key; keep points with `confidence > handPointConfidenceThreshold` (start 0.3, tunable).

**Face — target the mouth and nose regions, derive a chin exclusion zone.** From `FaceLandmarks` build three small AABBs (axis-aligned bounding boxes) in image-normalized space, padded slightly:
- `mouthBox` = bounding box of `outerLips` points, inflated by `regionPad`.
- `noseBox` = bounding box of `nose` + `noseCrest`, inflated by `regionPad`.
- `chinBand` = region below `medianLine`'s lowest point down to the face box's `minY` (the lower jaw). A fingertip in `chinBand` **without** also being in `mouthBox`/`noseBox` is treated as *resting*, not biting — it raises the bar (see §4).

If face landmarks are unavailable for a frame (occlusion, low confidence) fall back to a coarse `mouthBox`/`noseBox` synthesized from the face *box* fractions (mouth ≈ lower-center third, nose ≈ center) so detection degrades instead of dying.

### 4. Decision logic — `GestureDetector` (temporal) over `ProximityAnalyzer` (per-frame)

Split the decision into a **pure per-frame scorer** and a **pure stateful temporal model**.

**4a. Per-frame score (`ProximityAnalyzer`, evolved).** Replace the binary box test with a **soft proximity score per region**. For a region box `R` and the set of weighted fingertips `F`:

```
For each fingertip f (weight wₑ, confidence cₑ):
    d = signedDistanceToBox(f, R)          // 0 inside, >0 outside (normalized units)
    proximity = clamp(1 - d / reach, 0, 1) // reach = sensitivity-driven capture radius
    contribution = proximity * wₑ * cₑ
score(R) = sum(contributions) clamped to [0,1]
```

- `signedDistanceToBox` = euclidean distance from point to nearest edge of `R` (0 if inside). Pure CG math, trivially unit-testable.
- `mouthScore` and `noseScore` computed independently. The **chin penalty:** if the dominant contributing fingertips are inside `chinBand` but outside `mouthBox`, multiply `mouthScore` by `chinRestPenalty` (≈0.4). This is what discriminates "resting chin on hand" from "biting" — knuckles/palm resting register as low-fingertip, in-chin-band, out-of-mouth → suppressed.
- Output `FrameScore { mouthScore, noseScore, dominant: Region }`.

This keeps `ProximityAnalyzer` pure (only `CoreGraphics`) and preserves the existing test surface — the old `isHandInFace` becomes a thin wrapper (`mouthScore + noseScore > threshold`) so current tests can be kept or migrated intentionally.

**4b. Temporal model (`GestureDetector`).** A small pure state machine fed one `FrameScore` per frame (plus a frame timestamp / index). It applies:

- **Smoothing:** exponential moving average of each region score, `ema = α·score + (1-α)·ema` (α ≈ 0.5 at 10 fps ≈ 100 ms time constant), to kill single-frame jitter.
- **Hysteresis (two thresholds):** enter when `ema ≥ enterThreshold`; only leave when `ema ≤ exitThreshold` with `exitThreshold < enterThreshold` (e.g. 0.6 / 0.35). Prevents boundary flicker.
- **Sustain:** require the EMA to stay above `enterThreshold` for `minSustainedFrames` (≈3) before declaring a gesture — complementary to (and partially redundant with) `AlertManager`'s debounce; we keep both, detector-level sustain for signal cleanliness, AlertManager-level for user-facing cadence.
- **Region arbitration:** if both mouth and nose are active, pick the higher EMA → emit `.mouthContact` or `.noseContact`.

```swift
enum DetectionResult: Equatable {
    case none
    case mouthContact(confidence: Double)   // nail-biting
    case noseContact(confidence: Double)    // nose-poking
}

struct GestureDetector {
    var config: DetectorConfig
    private var mouthEMA = 0.0, noseEMA = 0.0
    private var sustainedMouth = 0, sustainedNose = 0
    private var active: DetectionResult = .none   // for hysteresis

    mutating func ingest(_ s: FrameScore) -> DetectionResult { /* pure */ }
}
```

`GestureDetector` is a `struct` with `mutating` methods → deterministic, snapshot-testable by replaying a fixture sequence of `FrameScore`s and asserting the emitted `DetectionResult` timeline.

### 5. Sensitivity mapping (0…1 → thresholds)

`AppSettings.sensitivity` (default 0.5) drives a single `DetectorConfig` derived deterministically so the relationship is documented and testable. Higher sensitivity = triggers earlier/easier:

```swift
struct DetectorConfig {
    var reach: CGFloat            // capture radius (normalized) for proximity falloff
    var enterThreshold: Double
    var exitThreshold: Double
    var regionPad: CGFloat        // mouth/nose box inflation
    var minSustainedFrames: Int
    var handPointConfidence: Float

    static func from(sensitivity s: Double) -> DetectorConfig {
        let s = min(max(s, 0), 1)
        return DetectorConfig(
            reach:            lerp(0.04, 0.14, s),   // tiny → generous capture radius
            enterThreshold:   lerp(0.75, 0.45, s),   // strict → lax
            exitThreshold:    lerp(0.45, 0.25, s),   // keep < enter (hysteresis)
            regionPad:        lerp(0.01, 0.05, s),
            minSustainedFrames: s > 0.66 ? 2 : (s > 0.33 ? 3 : 4),
            handPointConfidence: Float(lerp(0.5, 0.25, s))
        )
    }
}
```

End-stops: `s = 0` → very strict (fingertip must be *inside* the tight mouth/nose box, 4 sustained frames) — near-zero false positives, may miss light touches. `s = 1` → generous capture radius and lax thresholds — catches approaches early at the cost of more false positives. Default `0.5` lands in the middle. `AppState` rebuilds the config and assigns it to the detector whenever `settings.sensitivity` changes (Combine subscription on `$sensitivity`). The mapping function is pure → unit-tested directly (monotonicity, end-stops, `exit < enter` invariant).

### 6. Performance budget

**Frame throttling (≤10–12 fps).** Nail-biting is slow; processing every camera frame (30/60 fps) is wasteful. Add a `FrameThrottle` gate between `CameraManager.onFrame` and the detector that admits at most one frame per `1/targetFPS` interval and **drops** the rest. Combined with `videoOutput.alwaysDiscardsLateVideoFrames = true` (already set), this guarantees no backlog. Implementation: timestamp comparison on the camera queue; cheap.

```swift
final class FrameThrottle {
    let minInterval: CFTimeInterval   // e.g. 1.0/12
    private var lastAccepted: CFTimeInterval = 0
    func shouldProcess(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard now - lastAccepted >= minInterval else { return false }
        lastAccepted = now; return true
    }
}
```

**Downscale before Vision.** Vision does **not** need 720p+ to find a face/hands at desk distance. Downscale the accepted `CVPixelBuffer` to a longest-edge of ~**512 px** before building the `VNImageRequestHandler`. Options, in preference order:
1. **`CIImage` + `CIContext` (Metal-backed)** scale + render into a pooled small `CVPixelBuffer` — simplest, GPU-accelerated, reuse one `CIContext`.
2. `vImageScale_ARGB8888` (vImage/Accelerate) — lowest overhead, more code.
3. `CVPixelBufferPool` to recycle output buffers and avoid per-frame allocation.

Prefer **(1)** with a persistent `CIContext(options: [.useSoftwareRenderer: false])` and a `CVPixelBufferPool` for outputs. Alternatively, set the capture output's `videoSettings`/`AVCaptureVideoDataOutput` to deliver a smaller buffer and pin pixel format to `kCVPixelFormatType_32BGRA` to avoid format surprises for Core Image. Lowering `session.sessionPreset` to `.cif352x288`/`.vga640x480` (in plan 02) is a cheaper alternative to per-frame scaling; do both is unnecessary — **pick capture-side downscale if the preset is reliable across devices, else CI-scale**. Plan: start with `.vga640x480` preset + CI-scale to 512 longest edge (robust across external webcams).

**Neural Engine.** Both `VN*` requests run on the ANE/GPU automatically on Apple silicon; nothing to enable. Keep `VNImageRequestHandler` per-frame (cheap) — do **not** reuse a handler across buffers (unsupported). Reuse the **request objects** (already done in the stub) so model load happens once.

**Thermals / always-on.** Subscribe to `ProcessInfo.thermalStateDidChangeNotification`; on `.serious`/`.critical`, **halve** the target fps (12→6) and optionally widen the throttle. On `.nominal` restore. Pause entirely when not watching / screen locked (plan 02 owns lifecycle; detector just stops receiving frames). Log thermal transitions via `AppLogger.detection`.

**Drop-late discipline.** Camera queue: throttle + handoff only. Detection queue: serial; if a frame arrives while the previous is still being processed (shouldn't happen at 12 fps but possible under thermal load), **coalesce** — keep only the newest pending buffer (a single-slot mailbox), never queue up. This bounds latency and memory.

### 7. False-positive / false-negative mitigation

| Failure | Mitigation |
|---|---|
| Chin/cheek resting → false positive | `chinBand` penalty (§4a); require *fingertip* (not wrist/palm) inside mouth/nose box; palm-orientation heuristic from wrist→MCP vector. |
| Single-frame Vision jitter → false positive | EMA smoothing + `minSustainedFrames` + hysteresis (§4b); `AlertManager` debounce as backstop. |
| Hand partially occluded by face → false negative | Use *any* high-confidence fingertip; secondary DIP joints; generous `reach` at higher sensitivity. |
| Two hands / glasses-adjust vs nose-poke | Region arbitration picks dominant; nose-poke needs sustained fingertip *in* `noseBox`, brief glasses touches won't sustain. |
| Drinking / eating (cup to mouth) → false positive | Hard to fully solve without object detection (out of scope); cooldown + sustain reduce nag; documented limitation, revisit with a Create ML hand-action classifier later. |
| No face in frame | Emit `.none`; do not trigger on hands alone. |

**Measurement:** the fixture corpus (§9) is labeled per-frame (`positive-mouth`, `positive-nose`, `negative`). A test/offline harness replays recorded `FrameObservation` sequences through the *real* `GestureDetector` and computes recall, precision, and alerts-per-minute against labels — turning "feels right" into numbers we can regression-gate.

### 8. Threading model

- **Camera queue** (`com.shoo.camera.session`, serial): receives `CMSampleBuffer`, applies `FrameThrottle`, drops or forwards the `CVPixelBuffer` (+ derived orientation). No Vision here.
- **Detection queue** (`com.shoo.detection`, serial, `qos: .userInitiated`): downscale → run both `VN` requests → extract `FrameObservation` → `GestureDetector.ingest` → produce `DetectionResult`. Single-slot mailbox to coalesce late frames. `GestureDetector` state lives here and is **only** touched on this queue (no locking needed).
- **Main actor:** receives the final `DetectionResult` via `Task { @MainActor in … }` (as the stub already does) and forwards to `AlertManager`. No Vision, no geometry on main.
- **Config updates:** `sensitivity` changes arrive on main; hop to the detection queue (`detectionQueue.async`) to swap `DetectorConfig` so the detector's state isn't mutated cross-thread.

### 9. Testability

- **Purity boundary:** `ProximityAnalyzer`, `FaceGeometry`, `GestureDetector`, `DetectorConfig.from(sensitivity:)` import only `CoreGraphics`/`Foundation` — no Vision/AVFoundation. They are the bulk of the logic and are fully unit-tested.
- **`FrameAnalyzing` protocol** lets tests feed a `MockFrameAnalyzer` returning scripted `FrameObservation`s, so `HandFaceDetector`'s coordination (throttle, mailbox, config swap) is testable without a camera.
- **Fixture format:** record real sessions into JSON fixtures of `[FrameObservation]` (face box + landmark region points + hand joints with confidence) plus a per-frame label. Provide a small `Codable` `FrameObservationFixture`. A debug-build recorder (gated, not shipped) dumps live `FrameObservation`s to disk to grow the corpus. Tests load fixtures from the `ShooTests` bundle and assert the emitted `DetectionResult` timeline + aggregate metrics.

## Implementation steps

Ordered, file-by-file:

1. **Geometry types & purity scaffolding.** Add `Shoo/Detection/Models.swift` with `DetectionResult`, `FrameObservation`, `FaceLandmarks`, `HandLandmarks`, `FrameScore`, `Region` (`.mouth`/`.nose`/`.none`). All `Codable` where useful for fixtures. No Vision imports.
2. **`DetectorConfig`** — new `Shoo/Detection/DetectorConfig.swift` with the struct + `from(sensitivity:)` + `lerp`. Pure. Unit-test immediately (monotonicity, end-stops, `exit<enter`).
3. **`FaceGeometry`** — new `Shoo/Detection/FaceGeometry.swift`: builds `mouthBox`, `noseBox`, `chinBand` from `FaceLandmarks` (image-normalized), with face-box fallback. Pure. Unit-tested with hand-authored landmark fixtures.
4. **Evolve `ProximityAnalyzer`** — add the soft per-region scorer (`score(region:fingertips:) -> Double`, `frameScore(...) -> FrameScore`) and `signedDistanceToBox`. Keep `isHandInFace` as a thin wrapper so existing `ProximityAnalyzerTests` stay green. Pure.
5. **`GestureDetector`** — new `Shoo/Detection/GestureDetector.swift`: stateful pure struct with EMA, hysteresis, sustain, arbitration; `ingest(_:) -> DetectionResult`. Unit-tested via scripted `FrameScore` sequences.
6. **`FrameAnalyzing` + `VisionFrameAnalyzer`** — new `Shoo/Detection/VisionFrameAnalyzer.swift`: switch face request to `VNDetectFaceLandmarksRequest` (constellation 76), keep hand request, pin revisions, extract `FrameObservation` (select fingertips by `JointName`, convert face regions to image-normalized via `FaceGeometry.imageNormalized`). Conforms `FrameAnalyzing`. Plus `MockFrameAnalyzer` in tests.
7. **`FrameThrottle`** — new `Shoo/Detection/FrameThrottle.swift`. Pure timestamp gate. Unit-tested.
8. **Downscaling** — new `Shoo/Detection/FrameDownscaler.swift`: `CIContext` + `CVPixelBufferPool`, `downscale(_:longestEdge:) -> CVPixelBuffer`. (Vision-adjacent; tested manually/perf-wise.)
9. **Rewrite `HandFaceDetector`** as coordinator: holds `FrameAnalyzing`, `FrameDownscaler`, `GestureDetector`, `DetectorConfig`; `process(_:orientation:completion:)` runs the detection-queue pipeline (downscale → analyze → score via `ProximityAnalyzer`+`FaceGeometry` → `GestureDetector.ingest`) and returns `DetectionResult`. Add `updateConfig(_:)` (hops to detection queue). Single-slot mailbox for coalescing.
10. **`CameraManager`** — derive `CGImagePropertyOrientation` from the connection, surface mirroring, pin pixel format to BGRA, pass orientation through `onFrame` (signature `((CVPixelBuffer, CGImagePropertyOrientation) -> Void)`). (Throttle can live here or in detector; plan 02 coordinates lifecycle — implement the throttle gate call here, the `FrameThrottle` type ships from this plan.)
11. **`AppState`** — update `wirePipeline()` to pass orientation, consume `DetectionResult` (map `.none` → no alert, contact → alert), and subscribe to `settings.$sensitivity` to push `DetectorConfig.from(sensitivity:)` into the detector. `AlertManager.handleDetection` updated to take `DetectionResult` (or a derived `Bool` + region) — keep its debounce.
12. **Thermal handling** — subscribe to `ProcessInfo.thermalStateDidChangeNotification` in `HandFaceDetector` (or a small `ThermalGovernor`) to scale target fps.
13. **Fixtures + tests** — add `ShooTests/Fixtures/*.json`, `FrameObservationFixture`, `GestureDetectorTests`, `FaceGeometryTests`, `DetectorConfigTests`, `FrameThrottleTests`, and a metrics harness test.

## Files to create / modify

**Create**
- `Shoo/Detection/Models.swift` — `DetectionResult`, `FrameObservation`, `FaceLandmarks`, `HandLandmarks`, `FrameScore`, `Region` (pure, Codable).
- `Shoo/Detection/DetectorConfig.swift` — sensitivity→thresholds mapping (pure).
- `Shoo/Detection/FaceGeometry.swift` — mouth/nose/chin region extraction (pure).
- `Shoo/Detection/GestureDetector.swift` — temporal state machine: EMA, hysteresis, sustain, arbitration (pure).
- `Shoo/Detection/VisionFrameAnalyzer.swift` — `FrameAnalyzing` impl wrapping `VNDetectFaceLandmarksRequest` + `VNDetectHumanHandPoseRequest`.
- `Shoo/Detection/FrameThrottle.swift` — fps gate (pure).
- `Shoo/Detection/FrameDownscaler.swift` — Core Image / pool-based downscale.
- `ShooTests/GestureDetectorTests.swift`, `ShooTests/FaceGeometryTests.swift`, `ShooTests/DetectorConfigTests.swift`, `ShooTests/FrameThrottleTests.swift`, `ShooTests/DetectionMetricsTests.swift` — unit + metrics tests.
- `ShooTests/Fixtures/` (+ `FrameObservationFixture.swift`) — recorded landmark fixtures with per-frame labels.

**Modify**
- `Shoo/Detection/HandFaceDetector.swift` — becomes a coordinator over analyzer/downscaler/gesture/config; emits `DetectionResult`; orientation param; mailbox; thermal scaling.
- `Shoo/Detection/ProximityAnalyzer.swift` — add soft per-region scoring + `signedDistanceToBox`; keep `isHandInFace` wrapper.
- `Shoo/Camera/CameraManager.swift` — orientation + mirroring derivation, BGRA pin, throttle call, `onFrame` signature gains orientation.
- `Shoo/App/AppState.swift` — pass orientation, consume `DetectionResult`, push config on sensitivity change.
- `Shoo/Alerting/AlertManager.swift` — accept `DetectionResult` (keep debounce/cooldown).
- `ShooTests/ProximityAnalyzerTests.swift` — keep green; add region-scoring cases.

## Edge cases & risks

- **No face detected** (looking away, occluded): emit `.none`; never trigger on hands alone. Decay EMA toward 0.
- **Face landmarks low-confidence / missing** for some frames: fall back to face-box-fraction mouth/nose boxes so we degrade rather than blank out.
- **Hand occluded by face** during an actual bite (the worst case — the hand is *behind* the chin from the camera's view): rely on whatever fingertips remain visible + generous `reach`; accept some recall loss, documented.
- **Glasses / beard / mask** alter landmark accuracy: constellation-76 is robust but not perfect; padding + sustain absorb minor error.
- **Two people in frame:** we take the largest face only (existing behavior) — keep, document.
- **External webcam orientation/mirroring** differs from built-in: derive orientation per-connection, never hardcode (fixes current L24 bug).
- **Drinking/eating, phone-to-face, smoking:** genuine false-positive sources we can't fully eliminate without object/action classification (out of scope v1); cooldown limits nag. Flag as the top candidate for a future Create ML hand-action model.
- **Thermal throttling on fanless Macs** during long sessions: fps backoff + drop-late prevent runaway; verify on a MacBook Air.
- **Pixel format / Core Image mismatch:** pin BGRA; verify `CIContext` handles the capture format without per-frame conversion cost.
- **Coalescing correctness:** ensure the single-slot mailbox can't deadlock or drop the *only* frame during a quiet period (always process if no in-flight work).

## Testing & verification

**Unit (pure, fast, CI-gated)**
- `DetectorConfigTests`: monotonicity of every mapped field across `s ∈ {0, .25, .5, .75, 1}`; invariant `exitThreshold < enterThreshold` always; end-stop values.
- `FaceGeometryTests`: mouth/nose/chin boxes from authored landmark fixtures; face-box fallback path; `imageNormalized` math.
- `ProximityAnalyzerTests` (extended): `signedDistanceToBox` (inside=0, monotone outside); per-region `frameScore`; chin penalty suppresses a chin-band-only fingertip; existing 5 tests stay green.
- `GestureDetectorTests`: replay scripted `FrameScore` timelines — verify enter/exit hysteresis, sustain delay, EMA smoothing kills a 1-frame spike, region arbitration picks dominant, decay to `.none` on signal loss.
- `FrameThrottleTests`: admits ≤ targetFPS, drops in-between.

**Metrics (fixture corpus)**
- `DetectionMetricsTests`: replay labeled `FrameObservation` fixtures through real `GestureDetector`; assert **recall ≥ 0.90**, **false alerts ≤ threshold/min**, **onset latency ≤ 600 ms** at default sensitivity. Regression-gate these numbers.

**Manual protocol** (debug build, on-device)
1. Bite a nail → overlay within ~600 ms; release → no re-fire within cooldown.
2. Poke nose → fires; distinguish from glasses-adjust (brief, shouldn't sustain).
3. Rest chin on hand for 30 s → **no** fire (key acceptance).
4. Type / read / scratch head for 5 min → ≤ expected spurious rate.
5. Sweep sensitivity 0→1; confirm monotonic eagerness and no-trigger at 0 for borderline gestures.
6. External webcam + built-in: confirm orientation/mirroring both work.

**Performance measurement**
- `Instruments` Time Profiler: confirm no Vision/geometry on main thread; sustained CPU ≤ 8% of a P-core while idle-watching.
- `powermetrics` / Activity Monitor over a 1-hour run: stable memory (no leak), acceptable energy impact.
- Force thermal pressure (or simulate via `ProcessInfo`); confirm fps backoff engages and recovers.
- Verify frame coalescing: log dropped-vs-processed counts; processed ≈ target fps regardless of camera native rate.

## Dependencies & sequencing

- **Depends on `02 camera-lifecycle`** for: correct orientation/mirroring derivation, pixel-format pinning, session pause on lock/not-watching, and where the `FrameThrottle` ultimately lives. This plan *defines* `FrameThrottle` and the `onFrame` orientation signature change; plan 02 owns the surrounding session lifecycle. Coordinate the `CameraManager.onFrame` signature change between the two.
- **Unblocks `03 alerting-overlay`:** emits the richer `DetectionResult` (`.mouthContact` / `.noseContact`) that the overlay can use to tailor the message ("Stop biting!" vs "Hands off your nose!"). `AlertManager` integration point is specified here.
- **Consumes from `04 settings-onboarding`:** the `sensitivity` slider; this plan defines the `sensitivity → DetectorConfig` mapping that plan 04's UI drives. A future "calibration" onboarding step could record fixtures.
- **Feeds `06 testing-ci`:** the pure unit tests + fixture metrics harness are the detector's contribution to the CI gate; plan 06 wires them into the pipeline.
- **Largely independent of `05 appstore-distribution`** (no extra entitlements beyond camera, which plan 02/05 handle; no model bundle to notarize).

Recommended order: land the **pure types + `ProximityAnalyzer`/`GestureDetector`/`DetectorConfig` + tests** first (no camera needed, immediately CI-valuable), then `VisionFrameAnalyzer` + `HandFaceDetector` coordination, then integrate with `CameraManager` (jointly with plan 02), then wire `AppState`/`AlertManager`.

## Out of scope

- **Object/action classification** (drinking, smoking, phone-to-face disambiguation) — needs a Create ML hand-action model; future work.
- **Per-user calibration / on-device learning** of personal gesture thresholds — future onboarding feature.
- **Multi-face tracking** — we keep "largest face only".
- **The macOS 15+ Swift-native async Vision fast path** — noted as a future `@available` optimization; not implemented given the macOS 14 floor.
- **Camera session lifecycle, permissions, lock/sleep handling** — owned by plan 02.
- **Overlay rendering, message copy, screen placement, cooldown UX** — owned by plan 03 (this plan only emits the `DetectionResult`).
- **Settings UI and persistence** — owned by plan 04 (this plan only defines the mapping consuming `sensitivity`).
- **CI configuration** — owned by plan 06.
