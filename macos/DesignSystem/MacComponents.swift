import SwiftUI

/// Mac-native building blocks.
///
/// Deliberately *not* a port of the iOS `GlassComponents`. That set is built on
/// `.glassEffect`, floating cards and edge-to-edge colour, which read as a
/// phone app running in a window — the thing the Mac HIG asks you not to ship.
/// These use the materials AppKit already uses for sidebars, inspectors and
/// sheets, so the app looks like it belongs beside Mail rather than beside a
/// simulator.
enum MacMetrics {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 10
    static let rowSpacing: CGFloat = 2
    static let sidebarMin: CGFloat = 220
    static let sidebarIdeal: CGFloat = 260
    static let contentMin: CGFloat = 420
    static let detailMin: CGFloat = 360
}

/// A grouped container, the way a Mac settings pane or inspector groups things.
struct MacCard<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: MacMetrics.cardRadius)
                    .fill(tint?.opacity(0.08) ?? Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: MacMetrics.cardRadius)
                    .strokeBorder(tint?.opacity(0.25) ?? Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}

/// An inline message. The Mac counterpart of the iOS `InlineBanner`, with the
/// same four kinds so a shared message reads the same on both platforms.
struct MacBanner: View {
    typealias Kind = AppStore.BannerMessage.Kind

    var kind: Kind
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        MacCard(tint: kind.tint) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.icon)
                    .foregroundStyle(kind.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(localizable: title).font(.headline)
                    if let message {
                        Text(localizable: message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let actionTitle, let action {
                        Button(action: action) { Text(localizable: actionTitle) }
                            .buttonStyle(.link)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
                }
            }
        }
    }
}

/// The empty state, with its illustration.
///
/// Always pairs the drawing with a sentence and a button: a picture on its own
/// is decoration, and somebody looking at an empty window needs to know what to
/// do next, not be charmed.
struct MacEmptyState: View {
    var illustration: Illustration?
    var icon: String?
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            if let illustration {
                illustration
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 6) {
                Text(localizable: title)
                    .font(.title3.weight(.semibold))
                Text(localizable: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 380)

            if let actionTitle, let action {
                Button(action: action) { Text(localizable: actionTitle) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Cold launch. A determinate-looking spinner with a sentence, rather than a
/// bare one, so a slow network does not read as a hang.
struct MacLoadingView: View {
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(localizable: message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
