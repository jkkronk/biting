# Shoo — Production Readiness Plans

This directory holds the detailed implementation plans that take **Shoo** from the
current scaffold (a buildable skeleton with a stubbed detector) to a shippable Mac
App Store app. Each plan is self-contained and meant to be executed one at a time.

| # | Plan | Scope |
|---|------|-------|
| 01 | [Detection Engine](01-detection-engine.md) | Real hand-to-face detection: Vision face landmarks + hand pose, region targeting (mouth/nose), smoothing/hysteresis, sensitivity mapping, perf budget |
| 02 | [Camera & Capture Lifecycle](02-camera-lifecycle.md) | Robust `AVCaptureSession`, permission flow, device hot-swap, interruptions, pause on lock/sleep, thermal/power policy, `FrameSource` test seam |
| 03 | [Alerting & Overlay UX](03-alerting-overlay-ux.md) | Overlay animations, multi-display targeting, alert modes (overlay/sound/notification), snooze/escalation state machine, accessibility |
| 04 | [Settings, Onboarding & Menu UX](04-settings-onboarding.md) | First-run onboarding + permission priming, full preferences, scheduling, launch-at-login correctness, state-driven menu |
| 05 | [App Store Distribution & Compliance](05-appstore-distribution.md) | Signing/provisioning, entitlements review, app icon & assets, `PrivacyInfo.xcprivacy`, ASC listing, review-risk mitigation, submission |
| 06 | [Testing, CI & Release Engineering](06-testing-ci.md) | Test pyramid, mock frame source, SwiftLint, GitHub Actions CI, coverage gates, fastlane/release automation, Makefile |

## Recommended implementation order

The plans share a few seams, so order matters. Recommended sequence:

```
02 Camera ──▶ 01 Detection ──▶ 03 Alerting ──▶ 04 Settings/Onboarding ──▶ 05 App Store
   │                                                                          ▲
   └──────────────── 06 Testing/CI (start thin early, grow alongside) ───────┘
```

1. **02 — Camera & Lifecycle first.** It introduces the foundational seams everything
   else builds on: the `FrameSource` protocol (enables headless testing), the single
   camera/permission state source of truth (fixes the scaffold's never-updated
   `cameraStatus`), and the `pause()/resume()` power API that plan 03 relies on.
2. **01 — Detection Engine.** The core IP. Needs plan 02's frame delivery and the
   correct orientation/mirroring handling to interpret Vision coordinates.
3. **03 — Alerting & Overlay UX.** Consumes plan 01's richer `DetectionResult` and
   plan 02's pause API (e.g. lock-screen suppression).
4. **04 — Settings, Onboarding & Menu UX.** Wires up the user-facing knobs that
   plans 01 and 03 expose, and depends on plan 02's permission flow.
5. **05 — App Store Distribution.** Last functional gate: app icon, privacy manifest,
   signing, listing, and submission once the app actually works. (The icon and
   `PrivacyInfo.xcprivacy` pieces can be started anytime in parallel.)
6. **06 — Testing & CI runs alongside.** Stand up the GitHub Actions workflow + lint
   early (it's cheap and catches regressions immediately), then deepen tests as each
   feature plan lands. The mock seams it depends on are introduced by plans 01–03.

## Cross-plan seams to keep consistent

- **`FrameSource` protocol** (defined in 02) — used by 01's detector and 06's tests.
- **Detection result type** (`DetectionResult` enum in 01) — consumed by 03's presenter.
- **`pause()/resume()` API** (02) — invoked by 03 for lock/DND suppression.
- **`AppSettings` keys** — 01 (sensitivity, gesture mask), 03 (alert mode/sound),
  04 (scheduling, onboarding flag, launch-at-login) all extend it; 04 owns the
  schema-versioning/migration hook.
- **Injected `Clock` / presenter protocols** (03) — keep alerting logic unit-testable per 06.

## How to use these

Pick the next plan in the order above, read its `## Implementation steps`, implement,
then run the verification in its `## Testing & verification` section before moving on.
Each plan lists its own dependencies in `## Dependencies & sequencing`.
