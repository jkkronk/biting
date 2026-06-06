# Shoo

A macOS menu-bar app that watches you through the webcam and gently tells you to **stop** when you bring your hands to your face — nail-biting, nose-poking, and other unconscious habits.

All image processing happens **on-device** using Apple's Vision framework. No video, frames, or data ever leave your Mac.

> Status: **scaffold**. The project structure, build config, and a runnable skeleton are in place. The detection logic (`HandFaceDetector` + `ProximityAnalyzer`) is stubbed and not yet wired to fire real alerts.

## How it works

```
Camera (AVCaptureSession)
   → CameraManager           emits CVPixelBuffer frames
   → HandFaceDetector        Vision: face rectangles + hand pose (21 landmarks)
   → ProximityAnalyzer       pure logic: is a hand inside/near the face box?
   → AlertManager            debounce + cooldown
   → OverlayWindow           centered "✋ Stop!" overlay, auto-dismisses
```

The menu-bar UI lets you enable/disable watching, tune sensitivity and cooldown, and launch at login.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/PRIVACY.md`](docs/PRIVACY.md) for details.

## Requirements

- macOS 14.0 or later
- Xcode 15 or later
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

- [ ] Implement real hand-vs-face overlap detection and tune thresholds
- [ ] Reduce false positives (e.g. resting chin on hand vs. biting)
- [ ] App icon & menu-bar glyph
- [ ] Code signing, notarization, App Store submission

## Privacy

Shoo is camera-only and offline by design. It never records, stores, or transmits imagery. See [`docs/PRIVACY.md`](docs/PRIVACY.md).
