import SwiftUI

/// Drives the overlay's appear/disappear transition and reduce-motion state from
/// ``OverlayController`` (an AppKit object) into SwiftUI.
@MainActor
final class OverlayModel: ObservableObject {
    /// Toggled true on show, false on dismiss; drives the content scale/opacity.
    @Published var isVisible: Bool = false
    /// When true, skip the scale transform and use a plain cross-fade.
    @Published var reduceMotion: Bool = false
    /// The cheeky subtitle line; re-picked on every show (see ``StopMessages``).
    @Published var message: String = ""
    /// The bold headline; a random cheeky "Gotcha!"-style word, re-picked on every show.
    @Published var headline: String = ""
    /// A small camera snapshot shown in place of the ✋ emoji. `nil` when the snapshot
    /// setting is off or no frame was available — then the emoji is used instead.
    @Published var snapshot: NSImage?
}

/// The centered reminder shown when a hand reaches the face: a small camera snapshot (or a
/// ✋ fallback), a random cheeky headline, and a random cheeky subtitle — all from
/// ``StopMessages``, refreshed each time the overlay appears.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    /// Invoked by the ✕ button (or a tap when click-to-dismiss is on).
    var onDismiss: (() -> Void)?
    /// Invoked by the Snooze button.
    var onSnooze: (() -> Void)?

    @Environment(\.colorSchemeContrast) private var contrast

    /// Reduce Transparency → solid background instead of `.ultraThinMaterial`.
    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var isHighContrast: Bool { contrast == .increased }

    var body: some View {
        VStack(spacing: 12) {
            snapshotOrEmoji
            Text(model.headline)
                .font(.largeTitle.weight(.bold))
            Text(model.message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(isHighContrast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

            if onDismiss != nil || onSnooze != nil {
                HStack(spacing: 12) {
                    if onSnooze != nil {
                        Button("Snooze") { onSnooze?() }
                    }
                    if onDismiss != nil {
                        Button("Dismiss") { onDismiss?() }
                    }
                }
                .font(.caption)
                .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .overlay(border)
        // Dynamic Type scales the semantic fonts, capped so the 360×180 panel doesn't overflow.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        // Appear/disappear transition: cross-fade always; subtle scale unless reduce-motion.
        .scaleEffect(model.reduceMotion ? 1.0 : (model.isVisible ? 1.0 : 0.92))
        .opacity(model.isVisible ? 1.0 : 0.0)
        .animation(
            model.reduceMotion ? .easeInOut(duration: 0.12) : .easeOut(duration: 0.22),
            value: model.isVisible
        )
    }

    /// The camera snapshot with rounded corners echoing the panel, or the ✋ emoji fallback.
    @ViewBuilder
    private var snapshotOrEmoji: some View {
        if let snapshot = model.snapshot {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            Image(nsImage: snapshot)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 96, height: 96)
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        isHighContrast
                            ? AnyShapeStyle(Color(nsColor: .separatorColor))
                            : AnyShapeStyle(.white.opacity(0.15)),
                        lineWidth: isHighContrast ? 2 : 1
                    )
                )
                .accessibilityHidden(true)
        } else {
            Text("✋")
                .font(.system(size: 56))
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 24)
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 24)
            .strokeBorder(
                isHighContrast ? AnyShapeStyle(Color(nsColor: .separatorColor)) : AnyShapeStyle(.white.opacity(0.15)),
                lineWidth: isHighContrast ? 2 : 1
            )
    }
}

#Preview {
    OverlayView(model: {
        let m = OverlayModel()
        m.isVisible = true
        m.headline = StopMessages.randomHeadline()
        m.message = StopMessages.random()
        return m
    }())
    .frame(width: 360, height: 180)
}
