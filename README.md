# Shoo

A macOS menu-bar app that watches you through the webcam and gently tells you to **stop** when you bring your hands to your face — nail-biting, nose-poking, and other unconscious habits.

All image processing happens **on-device** using Apple's Vision framework. No video, frames, or data ever leave your Mac.

<p align="center">
  <img src="art/overlay-screenshot.png" alt="Shoo overlay: “Seen it! Step away from the face.” with Snooze and Dismiss buttons" width="420">
</p>

## How it works

```
Camera (AVCaptureSession)
   → CameraController        downscales each frame into an owned buffer on the session queue
   → HandFaceDetector        Vision: face landmarks + hand pose (21 landmarks)
   → ProximityAnalyzer       pure logic: fingertip proximity to mouth/nose regions
   → GestureDetector         temporal smoothing + hysteresis → DetectionResult
   → AlertManager            state machine: debounce + cooldown + escalation
   → OverlayController        centered "Seen it!" overlay, auto-dismisses
```

The menu-bar UI lets you enable/disable watching, tune sensitivity and cooldown, and launch at login.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/PRIVACY.md`](docs/PRIVACY.md) for details.

## Requirements

- macOS 14.0 or later
- Xcode 16 or later (the committed project uses `objectVersion = 77`)
- A built-in or external webcam

## Download

Grab the latest zipped `.app` from the [**Releases**](../../releases) page, unzip it, and
move **Shoo.app** to `/Applications`.

Shoo is **open source and unsigned** — it is **not** signed with a paid Apple Developer
certificate and **not** notarized. Everything runs on-device inside the macOS sandbox (the
app's only entitlement is camera access), so you can read exactly what it does before
trusting it. Because it isn't notarized, Gatekeeper will block the first launch. To open it:

- Right-click **Shoo.app** → **Open** → **Open** in the dialog, **or**
- if macOS still refuses ("damaged" / "cannot verify"), clear the quarantine flag:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Shoo.app
  ```

Prefer to build it yourself? See **Build & run** below.

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

Open issues and improvements are tracked in [`docs/AUDIT.md`](docs/AUDIT.md).

## Privacy

Shoo is camera-only and offline by design. It never records, stores, or transmits imagery. See [`docs/PRIVACY.md`](docs/PRIVACY.md).

## License

Shoo is released under the [MIT License](LICENSE).
