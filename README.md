# Shoo

A macOS menu-bar app that watches you through the webcam and gently tells you to **stop** when you bring your hands to your face — nail-biting, nose-poking, and other unconscious habits.

All image processing happens **on-device** using Apple's Vision framework. No video, frames, or data ever leave your Mac.

> Status: **working**. The full pipeline is implemented and wired end-to-end (camera → detection → alert → overlay), with a unit-tested pure-logic core. Remaining work (detection tuning, App Store signing/submission) is tracked in `plans/` and `docs/AUDIT.md`.

## How it works

```
Camera (AVCaptureSession)
   → CameraController        downscales frames, emits CVPixelBuffer on the capture queue
   → HandFaceDetector        Vision: face landmarks + hand pose (21 landmarks)
   → ProximityAnalyzer       pure logic: fingertip proximity to mouth/nose regions
   → GestureDetector         temporal smoothing + hysteresis → DetectionResult
   → AlertManager            state machine: debounce + cooldown + escalation
   → OverlayController        centered "✋ Stop!" overlay, auto-dismisses
```

The menu-bar UI lets you enable/disable watching, tune sensitivity and cooldown, and launch at login.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/PRIVACY.md`](docs/PRIVACY.md) for details.

## Requirements

- macOS 14.0 or later
- Xcode 16 or later (the committed project uses `objectVersion = 77`)
- A built-in or external webcam

## Build & run

The Xcode project is committed, so the simplest path is:

```sh
open Shoo.xcodeproj
```

Then select the **Shoo** scheme and run (⌘R).

Alternatively, regenerate the project from its spec ([`project.yml`](project.yml)) with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
bash scripts/bootstrap.sh   # installs xcodegen if needed, then `xcodegen generate`
```

Command-line build and test:

```sh
xcodebuild -project Shoo.xcodeproj -scheme Shoo build
xcodebuild -project Shoo.xcodeproj -scheme Shoo test
```

On first run, macOS will ask for **camera permission** — this is expected and required for the app to function.

## Project layout

```
Shoo/            App, Camera, Detection, Alerting, Views, Models, Support
ShooTests/       Unit tests for the pure detection logic
project.yml      XcodeGen spec (source of truth for the Xcode project)
scripts/         bootstrap / tooling
docs/            Architecture & privacy notes
```

## Roadmap

- [x] Real hand-to-face detection (face landmarks + hand pose, mouth/nose regions)
- [x] False-positive mitigation (chin-rest penalty, temporal hysteresis)
- [x] App icon & menu-bar glyph
- [ ] On-device threshold tuning from real-world use
- [ ] Code signing, notarization, App Store submission (see `plans/05-appstore-distribution.md`)

Open issues and improvements are tracked in [`docs/AUDIT.md`](docs/AUDIT.md).

## Privacy

Shoo is camera-only and offline by design. It never records, stores, or transmits imagery. See [`docs/PRIVACY.md`](docs/PRIVACY.md).
