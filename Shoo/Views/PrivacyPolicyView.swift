import SwiftUI

/// The privacy policy, bundled in-app and shown as a sheet from Settings → About.
///
/// The canonical copy lives in `docs/PRIVACY.md` (also used for App Store disclosures);
/// keep this text in sync with it.
struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            if let heading = section.heading {
                                Text(heading)
                                    .font(heading == Self.title ? .title2.weight(.semibold) : .headline)
                            }
                            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
    }

    // MARK: - Content

    private static let title = "Privacy"

    private struct Section: Identifiable {
        let id = UUID()
        let heading: String?
        let paragraphs: [String]
    }

    /// Mirrors `docs/PRIVACY.md`. Plain prose (no markdown bullets) so it renders cleanly here.
    private static let sections: [Section] = [
        Section(heading: title, paragraphs: [
            "Shoo is designed to be private by default."
        ]),
        Section(heading: "What Shoo does", paragraphs: [
            "Accesses the webcam only while watching is enabled.",
            "Processes each frame entirely on-device using Apple's Vision framework.",
            "Uses the result (face box + hand landmarks) solely to decide whether to show an on-screen reminder."
        ]),
        Section(heading: "What Shoo does NOT do", paragraphs: [
            "It does not record video or save still images.",
            "It does not upload, stream, or transmit any imagery or derived data anywhere.",
            "It does not include analytics, tracking, or third-party SDKs.",
            "It does not persist anything beyond your local preferences "
                + "(sensitivity, cooldown, launch-at-login) in UserDefaults."
        ]),
        Section(heading: "Permissions", paragraphs: [
            "Camera: required to observe hand-to-face gestures. macOS prompts on first use."
        ]),
        Section(heading: "Sandbox", paragraphs: [
            "The app runs in the macOS App Sandbox with only the camera entitlement. "
                + "No network, file, or other device entitlements are requested."
        ])
    ]
}

#Preview {
    PrivacyPolicyView()
}
