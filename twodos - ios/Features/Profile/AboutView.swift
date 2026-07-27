import SwiftUI
import CoreLocation

/// About, plus the connection diagnostics that used to be hidden behind a
/// debug-only panel in the Flutter app. They are useful to a real user too:
/// "is it me or is it them?" is answerable here.
struct AboutView: View {
    @Environment(AppStore.self) private var store
    @Environment(NotificationService.self) private var notifications
    @Environment(LocationService.self) private var location

    var body: some View {
        ZStack {
            ScreenBackground()

            ScrollView {
                VStack(spacing: 20) {
                    header
                    statusSection
                    permissionsSection
                    linksSection
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refreshAuthorization() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.accentColor.gradient)
            Text("twodos")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Version \(Bundle.main.appVersion)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Shared lists for two.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var statusSection: some View {
        GlassSection(
            title: "Connection",
            footer: "Live sync keeps both phones up to date instantly. When it drops, pull down on any screen to refresh manually — nothing is lost."
        ) {
            GlassRow(
                icon: store.isSocketConnected ? "bolt.fill" : "bolt.slash",
                iconTint: store.isSocketConnected ? Brand.success : Brand.warning,
                title: "Live sync",
                subtitle: store.isSocketConnected ? "Connected" : "Reconnecting…"
            )
            GlassDivider()
            GlassRow(
                icon: "server.rack",
                title: "Server",
                subtitle: APIClient.baseURL.host() ?? "twodos.app"
            )
        }
    }

    private var permissionsSection: some View {
        GlassSection(title: "Permissions") {
            GlassRow(
                icon: notifications.isAuthorized ? "bell.fill" : "bell.slash",
                iconTint: notifications.isAuthorized ? Brand.success : Brand.warning,
                title: "Notifications",
                subtitle: notificationStatusText
            )
            GlassDivider()
            GlassRow(
                icon: location.hasAnyPermission ? "location.fill" : "location.slash",
                iconTint: location.hasAlwaysPermission ? Brand.success
                    : (location.hasAnyPermission ? Brand.warning : .secondary),
                title: "Location",
                subtitle: locationStatusText
            )
            GlassDivider()
            GlassRow(
                icon: "gear",
                title: "Open iOS Settings",
                showsChevron: true,
                action: openSettings
            )
        }
    }

    private var notificationStatusText: String {
        switch notifications.authorization {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Not allowed — reminders can't reach you"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    private var locationStatusText: String {
        switch location.authorization {
        case .authorizedAlways: "Always — place reminders work in the background"
        case .authorizedWhenInUse: "While using twodos — place reminders only fire when the app is open"
        case .denied, .restricted: "Not allowed — place reminders are off"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    private var linksSection: some View {
        GlassSection(title: "More") {
            Link(destination: URL(string: "https://twodos.app/privacy")!) {
                GlassRow(icon: "hand.raised", title: "Privacy policy", showsChevron: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            GlassDivider()

            Link(destination: URL(string: "https://twodos.app/terms")!) {
                GlassRow(icon: "doc.text", title: "Terms of service", showsChevron: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            GlassDivider()

            Link(destination: URL(string: "mailto:support@twodos.app")!) {
                GlassRow(icon: "envelope", title: "Contact support", showsChevron: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
