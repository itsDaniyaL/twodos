import SwiftUI

/// Notification preferences.
///
/// The system permission is shown at the top as the thing everything else
/// depends on — if it is off, the switches below are honest about being
/// pointless rather than pretending to work.
struct NotificationSettingsView: View {
    @Environment(NotificationService.self) private var notifications
    @Environment(NotificationSettingsStore.self) private var settings
    @Environment(LocationService.self) private var location

    @State private var isSendingTest = false
    @State private var testSent = false

    var body: some View {
        @Bindable var settings = settings

        ZStack {
            ScreenBackground()

            ScrollView {
                VStack(spacing: 20) {
                    permissionCard

                    GlassSection(
                        title: "What to notify me about",
                        footer: "These only apply while notifications are allowed for twodos."
                    ) {
                        GlassRow(icon: "calendar.badge.clock", title: "Deadlines",
                                 subtitle: "Lists and items with a due date") {
                            Toggle("", isOn: $settings.deadlineReminders).labelsHidden()
                        }
                        GlassDivider()
                        GlassRow(icon: "alarm", title: "Alarms",
                                 subtitle: "The alarms you set on the Alarms tab") {
                            Toggle("", isOn: $settings.alarmAlerts).labelsHidden()
                        }
                        GlassDivider()
                        GlassRow(icon: "mappin.and.ellipse", title: "Location reminders",
                                 subtitle: "When you arrive at or leave a saved place") {
                            Toggle("", isOn: $settings.locationReminders).labelsHidden()
                        }
                        GlassDivider()
                        GlassRow(icon: "person.2", title: "Partner activity",
                                 subtitle: "Invites, and changes they make to shared lists") {
                            Toggle("", isOn: $settings.partnerActivity).labelsHidden()
                        }
                    }
                    .disabled(!notifications.isAuthorized)
                    .opacity(notifications.isAuthorized ? 1 : 0.5)

                    GlassSection(title: "How they behave") {
                        GlassRow(icon: "speaker.wave.2", title: "Play a sound") {
                            Toggle("", isOn: $settings.playSound).labelsHidden()
                        }
                        GlassDivider()
                        GlassRow(icon: "app.badge", title: "Show while I'm in twodos",
                                 subtitle: "Banners appear even when the app is open") {
                            Toggle("", isOn: $settings.showWhileUsingApp).labelsHidden()
                        }
                    }
                    .disabled(!notifications.isAuthorized)
                    .opacity(notifications.isAuthorized ? 1 : 0.5)

                    locationCard
                    testButton
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refreshAuthorization() }
    }

    // MARK: - Permission

    @ViewBuilder
    private var permissionCard: some View {
        switch notifications.authorization {
        case .notDetermined:
            InlineBanner(
                kind: .info,
                title: "Notifications aren't set up yet",
                message: "We'll ask the first time you set a deadline or an alarm — or you can turn them on now.",
                actionTitle: "Turn on notifications",
                action: { Task { await notifications.requestAuthorizationIfNeeded() } }
            )
        case .denied:
            InlineBanner(
                kind: .warning,
                title: "Notifications are turned off",
                message: "Deadlines, alarms, and location reminders can't reach you until you allow notifications in Settings.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        default:
            InlineBanner(
                kind: .success,
                title: "Notifications are on",
                message: "twodos can send you reminders."
            )
        }
    }

    /// Location deserves its own explanation here, because "why didn't my
    /// shopping reminder fire?" is almost always this permission.
    @ViewBuilder
    private var locationCard: some View {
        if location.needsAlwaysUpgrade {
            InlineBanner(
                kind: .warning,
                title: "Location reminders only work in the app",
                message: "twodos can currently only check your location while it's open. Allowing location \"Always\" lets reminders find you even when the app is closed.",
                actionTitle: "Allow always",
                action: { location.requestAlways() }
            )
        } else if location.isDenied {
            InlineBanner(
                kind: .info,
                title: "Location is off",
                message: "You can still use every other part of twodos — only place-based reminders need it.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        }

        // iOS caps an app at 20 monitored regions, and Low Power Mode lowers
        // that further. The client has always silently dropped the least urgent
        // ones past the cap; saying so is the difference between a reminder that
        // is off and a reminder the user believes is on.
        //
        // This became worth surfacing once individual items could be pinned:
        // reaching the cap used to take twenty separate lists, which almost
        // nobody had.
        if location.droppedPlaceCount > 0 {
            InlineBanner(
                kind: .warning,
                title: "Watching \(location.monitoredCount) place\(location.monitoredCount == 1 ? "" : "s")",
                message: droppedPlacesMessage
            )
        }
    }

    private var droppedPlacesMessage: String {
        let dropped = location.droppedPlaceCount
        let noun = dropped == 1 ? "place isn't" : "places aren't"
        let base = "\(dropped) more \(noun) being watched — iOS limits how many "
            + "twodos can track at once, so the least urgent ones wait their turn."
        return location.isConservingPower
            ? base + " Low Power Mode is on, which lowers the limit further."
            : base
    }

    private var testButton: some View {
        VStack(spacing: 8) {
            SecondaryButton(
                title: testSent ? "Sent — check your banners" : "Send a test notification",
                icon: testSent ? "checkmark" : "paperplane"
            ) {
                Task {
                    isSendingTest = true
                    await notifications.requestAuthorizationIfNeeded()
                    await notifications.sendTestNotification(sound: settings.playSound)
                    isSendingTest = false
                    withAnimation(Motion.tap) { testSent = true }
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(Motion.fade) { testSent = false }
                }
            }
            .disabled(isSendingTest)

            Text("Sends one notification right now so you can check how it looks and sounds.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.top, 4)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
