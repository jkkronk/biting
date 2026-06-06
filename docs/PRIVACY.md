# Privacy

Shoo is designed to be private by default.

## What Shoo does

- Accesses the webcam **only** while watching is enabled.
- Processes each frame **entirely on-device** using Apple's Vision framework.
- Uses the result (face box + hand landmarks) solely to decide whether to show an on-screen reminder.

## What Shoo does NOT do

- It does **not** record video or save still images.
- It does **not** upload, stream, or transmit any imagery or derived data anywhere.
- It does **not** include analytics, tracking, or third-party SDKs.
- It does **not** persist anything beyond your local preferences (sensitivity, cooldown, launch-at-login) in `UserDefaults`.

## Permissions

- **Camera** (`NSCameraUsageDescription`): required to observe hand-to-face gestures. macOS prompts on first use.

## App Store privacy disclosures

When filling out App Store Connect's privacy questionnaire, the intended answers are:

- **Data collection:** None.
- **Data linked to you:** None.
- **Data used to track you:** None.

Camera input is used transiently in-memory and never leaves the device, so it does not constitute "data collection" under Apple's definition. If this changes (e.g. opt-in diagnostics are ever added), this document and the disclosures must be updated first.

## Sandbox

The app runs in the macOS App Sandbox with only the camera entitlement
(`com.apple.security.device.camera`). No network, file, or other device
entitlements are requested.
