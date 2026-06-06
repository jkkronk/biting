import AVFoundation
import SwiftUI

/// First-run onboarding + camera-permission priming, presented in a focusable `Window` while
/// the app temporarily runs as `.regular` (see ``ShooAppDelegate``).
///
/// A simple paged step machine: Welcome → Privacy → Camera access → All set. The macOS camera
/// prompt fires only at the explicit "Enable Camera Access" tap — never on launch.
struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int {
        case welcome, privacy, camera, done
    }

    @State private var step: Step = .welcome
    @State private var requesting = false
    @State private var cameraOutcome: CameraPermission.Status?

    var body: some View {
        VStack(spacing: 24) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .padding(32)
        .frame(width: 460, height: 420)
        // If the user closes the window early, still mark onboarded and restore .accessory.
        .onDisappear { finish(markOnboarded: true, startIfPossible: false) }
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            stepBody(
                symbol: "hand.raised.fill",
                title: "Welcome to Shoo",
                message: "Shoo gently reminds you when you bring your hands to your face — to help you stop nail-biting and other nervous habits."
            )
        case .privacy:
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Private by design")
                    .font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 8) {
                    privacyBullet("All processing happens on-device with Apple Vision.")
                    privacyBullet("Nothing is ever recorded or saved.")
                    privacyBullet("No network access — your video never leaves your Mac.")
                    privacyBullet("Sandboxed and built for the Mac App Store.")
                }
            }
        case .camera:
            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Enable camera access")
                    .font(.title2.weight(.semibold))
                Text("Shoo needs to see your webcam to notice face-touching. macOS will ask for permission next.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let outcome = cameraOutcome, outcome != .authorized {
                    deniedNotice
                }
            }
        case .done:
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("You're all set")
                    .font(.title2.weight(.semibold))
                Toggle("Start watching now", isOn: Binding(
                    get: { appState.settings.startWatchingOnLaunch },
                    set: { appState.settings.startWatchingOnLaunch = $0 }
                ))
                .toggleStyle(.switch)
                .padding(.top, 8)
            }
        }
    }

    private func stepBody(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private func privacyBullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
    }

    private var deniedNotice: some View {
        VStack(spacing: 8) {
            Text("Camera access was not granted.")
                .foregroundStyle(.secondary)
            Button("Open System Settings") {
                SystemSettings.openCameraPrivacy()
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        switch step {
        case .welcome:
            Button("Continue") { step = .privacy }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        case .privacy:
            HStack {
                Button("Back") { step = .welcome }
                Button("Continue") { step = .camera }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        case .camera:
            if cameraOutcome == nil {
                Button(requesting ? "Requesting…" : "Enable Camera Access") {
                    requestAccess()
                }
                .disabled(requesting)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            } else {
                Button("Continue") { step = .done }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        case .done:
            Button("Done") { finishAndClose() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    // MARK: - Actions

    private func requestAccess() {
        requesting = true
        Task {
            await appState.requestCameraAccess()
            cameraOutcome = appState.cameraStatus
            requesting = false
            if appState.cameraStatus == .authorized {
                step = .done
            }
        }
    }

    /// Mark onboarded, optionally start watching, restore `.accessory`, and dismiss.
    private func finishAndClose() {
        finish(markOnboarded: true, startIfPossible: true)
        dismiss()
    }

    private func finish(markOnboarded: Bool, startIfPossible: Bool) {
        if markOnboarded {
            appState.settings.hasOnboarded = true
        }
        if startIfPossible,
           appState.settings.startWatchingOnLaunch,
           appState.cameraStatus == .authorized {
            appState.startWatching()
        }
        appState.onOnboardingFinished?()
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState())
}
