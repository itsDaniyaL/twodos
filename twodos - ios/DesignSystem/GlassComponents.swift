import SwiftUI

// MARK: - Glass card

/// The workhorse surface: a list card, an info panel, a banner.
///
/// Uses the iOS 26 `glassEffect` so the card genuinely refracts what scrolls
/// beneath it. Under Reduce Transparency it falls back to an opaque
/// `.regularMaterial`-equivalent fill, because a glass card that cannot be seen
/// through is worse than an honest solid one.
struct GlassCard<Content: View>: View {
    var tint: Color?
    /// How strongly `tint` colours the surface. The default is a hint; list
    /// cards raise it so a list's own colour is legible across the whole card
    /// rather than only in a strip down one edge.
    var tintStrength: Double = 0.09
    var interactive: Bool = false
    var radius: CGFloat = Metrics.cardRadius
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .overlay {
                            // Glass is off, so the tint has to be painted on
                            // directly or the card loses its colour entirely.
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill((tint ?? .clear).opacity(tintStrength * 1.4))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                }
            }
            .glassEffect(glass, in: .rect(cornerRadius: radius))
    }

    private var glass: Glass {
        if reduceTransparency { return .identity }
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(tintStrength)) }
        if interactive { g = g.interactive() }
        return g
    }
}

private extension Glass {
    /// A no-op glass used when Reduce Transparency is on and the real fill is
    /// drawn behind it instead.
    static var identity: Glass { .regular.tint(.clear) }
}

// MARK: - Section container

/// A titled group of rows, styled like an inset grouped list section but built
/// from glass so it sits correctly over scrolling content.
struct GlassSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .padding(.horizontal, 20)
                    .accessibilityAddTraits(.isHeader)
            }
            GlassCard {
                VStack(spacing: 0) { content }
            }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A single row inside a ``GlassSection``.
struct GlassRow<Trailing: View>: View {
    var icon: String?
    var iconTint: Color?
    var title: String
    var subtitle: String?
    var showsChevron: Bool = false
    var role: ButtonRole?
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Group {
            if let action {
                Button(role: role, action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 14) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(role == .destructive ? Brand.danger : (iconTint ?? .accentColor))
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(role == .destructive ? Brand.danger : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}

extension GlassRow where Trailing == EmptyView {
    init(
        icon: String? = nil,
        iconTint: Color? = nil,
        title: String,
        subtitle: String? = nil,
        showsChevron: Bool = false,
        role: ButtonRole? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(
            icon: icon,
            iconTint: iconTint,
            title: title,
            subtitle: subtitle,
            showsChevron: showsChevron,
            role: role,
            action: action,
            trailing: { EmptyView() }
        )
    }
}

/// Hairline divider matched to the inset of ``GlassRow``'s text column.
struct GlassDivider: View {
    var inset: CGFloat = Metrics.cardPadding + 40
    var body: some View {
        Divider()
            .padding(.leading, inset)
            .opacity(0.6)
    }
}

// MARK: - Buttons

/// The primary call to action. Prominent glass so it reads as the one thing to
/// press, with a subtle press-scale that makes the button feel like a physical
/// key rather than a rectangle that changes colour.
struct PrimaryButton: View {
    var title: String
    var icon: String?
    var isLoading: Bool = false
    var role: ButtonRole?
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .transition(.scale.combined(with: .opacity))
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(isLoading ? "Please wait…" : title)
                    .font(.body.weight(.semibold))
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(role == .destructive ? Brand.danger : .accentColor)
        .disabled(isLoading)
        .motion(Motion.tap, value: isLoading)
        .opacity(isEnabled ? 1 : 0.55)
    }
}

/// The secondary action beside a ``PrimaryButton``.
struct SecondaryButton: View {
    var title: String
    var icon: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

// MARK: - Chips

/// A small piece of metadata: a deadline, a partner, a location.
struct MetaChip: View {
    var icon: String
    var text: String
    var tint: Color = .secondary
    var emphasised: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption2.weight(emphasised ? .semibold : .regular))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(tint.opacity(emphasised ? 0.12 : 0.07))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A tappable suggestion chip, used for quick deadline presets.
struct SuggestionChip: View {
    var title: String
    var isSelected: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 6)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .tint(isSelected ? .accentColor : .primary)
    }
}

// MARK: - Empty state

/// Shown whenever a collection is empty. Always pairs a reason with an action —
/// an empty screen that only says "nothing here" leaves the user stuck.
struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.75))
                .symbolEffect(.bounce, value: appeared)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
        .motion(Motion.content, value: appeared)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Inline banner

/// A non-blocking message inside the content, used for errors and for the
/// "turn on notifications" nudge. Deliberately not an alert: an alert stops the
/// user, and neither of those cases is worth stopping for.
struct InlineBanner: View {
    enum Kind { case info, warning, error, success

        var icon: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "exclamationmark.circle.fill"
            case .success: "checkmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: Brand.info
            case .warning: Brand.warning
            case .error: Brand.danger
            case .success: Brand.success
            }
        }
    }

    var kind: Kind
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        GlassCard(tint: kind.tint, radius: Metrics.controlRadius) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(kind.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(kind.tint)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }
            .padding(14)
        }
        .transition(.banner)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Loading

/// A full-screen loading state. Uses a shaped, branded indicator rather than a
/// bare spinner so cold launch does not look like a hang.
struct LoadingView: View {
    var message: String?
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 76, height: 76)
                    .scaleEffect(pulse ? 1.12 : 0.92)
                // The brand mark rather than a spinner: a cold launch that shows
                // the app's own identity reads as "starting up", where a bare
                // spinner reads as "stuck".
                TwodosMark(tickStyle: AnyShapeStyle(Color.accentColor))
                    .frame(width: 34, height: 34)
            }
            .accessibilityHidden(true)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel(message ?? "Loading")
    }
}

// MARK: - Screen background

/// The app-wide backdrop. A soft, very low-contrast accent wash that gives the
/// glass something to refract — plain white produces flat, lifeless glass.
///
/// Set `showsHorizon` on the app's "front door" screens to bring in the icon's
/// hill and clouds. It is deliberately *not* on every screen: as a recurring
/// motif it would compete with content, but as a welcome and empty-state
/// treatment it ties the app back to its icon.
struct ScreenBackground: View {
    var showsHorizon: Bool = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(scheme == .dark ? 0.09 : 0.055),
                    Color.accentColor.opacity(0.0)
                ],
                startPoint: .topLeading,
                endPoint: .center
            )

            if showsHorizon {
                IconLandscape()
                    .opacity(scheme == .dark ? 0.22 : 0.30)
            } else {
                LinearGradient(
                    colors: [
                        Color.clear,
                        Brand.meadowSoft.opacity(scheme == .dark ? 0.09 : 0.06)
                    ],
                    startPoint: .center,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}
