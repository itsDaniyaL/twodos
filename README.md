# twodos — native iOS and watchOS

A full native rewrite of the twodos Flutter app in SwiftUI, targeting iOS 26.5
and watchOS 26.5.

**Zero third-party dependencies.** Everything is Apple frameworks, including a
hand-written Socket.IO v4 client that replaces `socket_io_client`.

```bash
open "twodos - ios.xcodeproj"
# or
xcodebuild -scheme "twodos - ios" -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme "twodos - watchos Watch App" -destination 'generic/platform=watchOS Simulator' build
```

---

## Layout

`Shared/` is a filesystem-synchronized group belonging to **both** targets, so
the models and networking layer exist once. Platform-specific pieces are behind
`#if os(watchOS)`.

```
Shared/            Models, APIClient, APIError, TokenStore, Theme,
                   Formatters, IconElements, WatchPayload

twodos - ios/
├── App/              TwodosApp, RootView, MainTabView
├── DesignSystem/     Motion, GlassComponents
├── Networking/       SocketClient
├── Services/         NotificationService, LocationService, Haptics,
│                     PhoneConnectivityService
├── Stores/           AppStore, ThemeStore, NotificationSettingsStore
└── Features/
    ├── Auth/         Welcome, SignIn, SignUp, VerifyEmail, OTP, Reset, Invite
    ├── Lists/        ListsView, ListCard, CreateListSheet, SortSheet
    ├── ListDetail/   ListDetailView, TodoRow, Options, Info, DeadlineSheet
    ├── Location/     LocationPickerView (MapKit)
    ├── Alarms/       AlarmsView, CreateAlarmSheet
    ├── Notifications/ActivityView
    ├── Partners/     PartnersView, ReportSheet
    └── Profile/      Profile, Appearance, Notifications, Security, About, Delete

twodos - watchos Watch App/
├── App/              TwodosWatchApp, WatchRootView
├── Views/            WatchListsView (Up next + Lists), WatchListDetailView
└── Support/          WatchStore, WatchConnectivityBridge, WatchHaptics
```

---

## Architecture

**`AppStore`** is the single `@Observable` source of truth. Every mutation is
optimistic: apply locally, call the API, reconcile — or roll back and surface the
error. The Flutter app awaited a round trip *and* a full list re-fetch before
showing a checkbox as ticked; this one responds on the same frame as the tap.

**`APIClient`** is an actor. It parses the API's `{statusCode, data}` envelope
(the server answers HTTP 200 for everything — see `API-REVIEW.md` §1.1),
serialises token refresh through one in-flight task, and retries once on 401.

**`SocketClient`** is an actor implementing enough of Engine.IO + Socket.IO v4
over `URLSessionWebSocketTask` to carry the app's events, with exponential
backoff and heartbeat-loss detection. Events carry an `actorId` so the client
ignores echoes of its own writes.

---

## What changed from the Flutter app

### Maps
OpenStreetMap tiles and Nominatim search → **Apple Maps**: vector tiles,
`MKLocalSearch`, real points of interest, a to-scale `MapCircle` for the
geofence radius, and a Look Around preview so you can confirm you pinned the
right doorway.

### Location reminders
A foreground `getPositionStream` polling loop → **`CLMonitor`**. The system wakes
the app on a real boundary crossing, even from a cold start. Reminders now arrive
when you get to the shop rather than when you next open the app.

### Session storage
Access and refresh tokens moved from `SharedPreferences` (an unencrypted plist on
iOS, readable from a filesystem backup) to the **Keychain**, with
`kSecAttrAccessibleAfterFirstUnlock` so background geofence triggers can still
reach the API while the phone is locked. The saved-password copy the Flutter app
kept is gone entirely — AutoFill handles it.

### Permissions
Nothing is requested at launch.

| Permission | Asked when | Why then |
|---|---|---|
| Notifications | First deadline, alarm, or location reminder is saved | The prompt arrives with obvious context |
| Location (When In Use) | "Use my location" is tapped, or a place is saved | Browsing the map needs no access |
| Location (Always) | *After* a location reminder exists | Nothing to justify it before that |

Each denied state has an inline explanation and a route to Settings — nothing
fails silently.

### Identity
The app icon (`AppIcon.icon`) is now the source of the design language rather
than a thing bolted on at the end:

- **The mark** — two ticks against two rules — is redrawn as a SwiftUI shape
  (`TwodosMark`) and used for the onboarding hero, the launch state, the "all
  done" moment on a finished list, and throughout the watch app. It replaces the
  `checklist` SF Symbol, which is one tick, one empty circle and three rules —
  quietly saying something other than *two* dos.
- **The scene** — the peach capsule clouds and the sage hill — is redrawn as
  vector shapes (`IconLandscape`) and used as the backdrop on the app's front
  door, so launching the app continues the picture the user just tapped.
- **The palette** is sampled from the icon. Meadow (`#53907C`) is now the
  default accent, with apricot (`#F3C1A8`) alongside it.

### Interface
- **Liquid Glass** throughout: `glassEffect`, `.buttonStyle(.glass)` /
  `.glassProminent`, a minimizing tab bar, soft scroll-edge effects, and zoom
  navigation transitions from list card to detail.
- **Four tabs** instead of icons buried in a nav bar. Alarms and Activity were
  previously undiscoverable; the notification badge now sits where iOS users
  look for it.
- **Information hierarchy on list cards.** A personal list with no deadline shows
  two lines; a shared, urgent, geofenced one shows five. The Flutter card always
  reserved space for every field.
- **Search covers item text**, not just list names — "milk" finds *Groceries*.
- **Swipes and context menus** replace the two small trailing buttons that
  crowded every todo row.

### Colour and theme
The palette is deliberately quiet, taking its register from the icon. Two rules
hold it together: colour carries meaning rather than decoration, and nothing is
fully saturated — a screen of todo items is something people look at for a long
time. Every brand colour has a considered dark-mode value rather than one fixed
hex (`Theme.swift`).

On top of light/dark, users pick an **accent** (seven options, including a
Graphite that removes hue entirely) and an in-app **text size** that layers on
top of system Dynamic Type rather than overriding it.

### Onboarding
The welcome screen is the mark, the name, one sentence and two buttons. It does
not scroll, by design. An earlier draft carried four feature cards explaining
sync, geofencing, deadlines and sharing — none of which a signed-out person can
act on or evaluate. Those explanations now appear where they are useful: at the
point each feature is first used.

### Motion
All animation is named and centralised in `Motion.swift`, and everything degrades
to a plain fade under Reduce Motion. Glass falls back to opaque fills under
Reduce Transparency.

---

## Configuration notes

- **Bundle ID** is unchanged from the Xcode template:
  `com.afzaalahmadzeeshan.ios.twodos.twodos---ios`. Change it before shipping.
- **Sign in with Apple** needs the capability enabled on the App ID in the
  developer portal before a device build will sign. Simulator builds work as-is.
- **API base URL** is in `APIClient.baseURL` — staging in Debug, `twodos.app` in
  Release, with a `useLocalServer` flag for local development.
- `AppStore+Sample.swift` provides fixture data for SwiftUI previews. Debug only.

### Emailed codes
Verification, password-reset, invite and deletion tokens are **alphanumeric and
of no fixed length**, so the code field is one wide monospaced input rather than
a row of digit boxes with a number pad. Case is preserved exactly as typed —
silently upper-casing would turn a valid case-sensitive token into a rejected
one.

---

## The watch app

Independent, not a mirror. The phone owns authentication and hands the watch a
session over `WatchConnectivity`; after that the watch talks to the API itself,
so it works with the phone switched off.

| | |
|---|---|
| **Up next** | Everything outstanding across every list, soonest deadline first. The landing view, because on a wrist the question is "what do I need to do", not "which list was it in". |
| **Lists** | The same content organised as on the phone, with a progress ring per list. |
| **Ticking off** | The whole row is the target. Applies instantly, syncs after, and replays if it happened offline. |
| **Adding** | `TextFieldLink` hands off to the system input screen — dictation, Scribble, emoji and a paired keyboard, all for free. |
| **Offline** | Lists are cached to disk and drawn on the first frame; ticks queue and replay on reconnect. |
| **Haptics** | The screen is often out of view at the moment of the tap, so the tap back *is* the confirmation. |

The watch deliberately holds **no refresh token**: two devices refreshing one
session race, and the API revokes every session when it sees that. When the
token expires the watch says so and points at the phone.

**Not yet built:** a complication / Smart Stack widget showing the outstanding
count and next deadline. That needs a new widget-extension target, which is
worth adding in Xcode directly rather than by editing the project file — it is
the highest-value remaining watch feature.

---

See **`API-REVIEW.md`** for the API analysis and the prioritised list of
suggested server and client changes.


Blocking push (only you can do these):

1. APNs key — create a .p8 in the Apple Developer portal. Gives you the key file, a Key ID, and your Team ID (V2Y9RFPG3D).
2. Add aps-environment to the iOS entitlements. Without it push fails on device regardless of server state.
3. Firebase project + service-account JSON for Android.
4. Set APNS_PRIVATE_KEY, and the apns_key_id / apns_team_id / apns_default_topic / fcm_project_id config rows.