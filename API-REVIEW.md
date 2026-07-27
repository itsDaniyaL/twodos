# twodos API — review and recommendations

Written while porting the Flutter client to native iOS. Every point below came
from actually implementing against the API, not from reading the spec.

Reference: `openapi.json` (twodos API 1.0.14), the Flutter client's
`lib/services/api_service.dart`, and the Socket.IO contract in
`lib/services/socket_service.dart`.

---

## 1. How the API actually behaves

### 1.1 The envelope

Every endpoint returns **HTTP 200**, with the real status inside the body:

```json
{ "statusCode": 200, "data": … }
{ "statusCode": 404, "statusMessage": "…" }
```

The native client therefore ignores `URLResponse.statusCode` entirely and
parses `statusCode` out of the body (`APIClient.perform`).

**This is the single biggest thing I'd change.** Consequences today:

| Cost | Detail |
|---|---|
| No HTTP caching | `URLSession`, CDNs, and proxies cannot cache a 200 that is really a 404. |
| No standard retry | Alamofire/URLSession retry policies key off status codes and are useless here. |
| Monitoring is blind | Every APM tool reports a 100% success rate, including outages. |
| Client-side branching | Each call site needs bespoke logic to tell success from failure. |

**Recommendation:** move to real status codes, and keep the envelope only as an
error *body* (RFC 9457 `application/problem+json` is the obvious choice). Ship it
as `/api/v2` and leave v1 running — the Flutter app is in the field and cannot be
force-updated.

### 1.2 Inconsistencies found while porting

These each cost a special case in the client. They're small individually, but
together they mean no generic layer can be trusted.

| # | Endpoint | Behaviour | Where it hurt |
|---|---|---|---|
| 1 | `GET /api/account/me` | Returns the user's fields at the **top level** of the envelope, not inside `data`. | The generic layer had to learn that a payload can live at the envelope's root (`PayloadLocation.root`). Worth stressing how expensive this one exception is: a decoder that assumes `data` finds nothing there, and the failure surfaces as "success with no data" on the single most load-bearing call in the app — the one every sign-in and every cold launch depends on. |
| 2 | `GET /api/account/partners` | Returns a bare array on some deployments, `{ "partners": [...] }` on others. The Flutter client has an explicit workaround for this. | `FlexibleArray` decoder that accepts both. |
| 3 | Mutating endpoints | `data` is variously `true`, `"OK"`, `"The Todo #x has been deleted."`, or absent. | `FlexibleTrue` decoder that normalises all four. |
| 4 | Priority | `GET /api/todos` documents the enum as `URGENT`/`NONURGENT`, but the wire format is `TODOLIST::PRIORITY::URGENT`. The spec is wrong. | Would have broken priority silently if I'd trusted the spec. |
| 5 | Dates | Mixed ISO-8601, some with fractional seconds, some without. | Custom `dateDecodingStrategy` trying both. |

### 1.3 Endpoints the app uses that are missing from `openapi.json`

The spec is behind the implementation. These are all in production use by the
Flutter client:

- `PATCH /api/todos/{listId}/{itemId}/done`
- `PATCH /api/todos/{listId}/{itemId}/title`
- `PATCH /api/account/me` — update display name
- `GET /api/account/invites` — pending invites
- `GET /api/notifications`, `PATCH /api/notifications/{id}/read`, `POST /api/notifications/read-all`
- `GET /api/block`, `POST /api/block/{userId}`, `DELETE /api/block/{userId}`
- `POST /api/account/refresh` — documented, but the `refreshToken` /
  `refreshExpiresAt` fields it returns are not
- `alarmTarget` on the deadline endpoints

**Recommendation:** generate `openapi.json` from the route definitions rather
than maintaining it by hand. A spec that is 6+ endpoints behind is worse than no
spec, because it invites clients to trust it.

### 1.4 Emailed tokens are alphanumeric and unbounded

Verification, password-reset, invite and account-deletion tokens can contain
letters as well as digits, and the spec states no length. Neither is documented,
and it is easy to assume otherwise — the Flutter client's `Validators.otp` and
this client's first draft both treated them as short numeric codes, which makes
any token containing a letter impossible to type on a number pad.

**Recommendation:** document the character set and length in the spec, and say
whether comparison is case-sensitive. The iOS client currently preserves case
exactly as typed because it cannot know.

### 1.5 Session semantics worth documenting

Three behaviours that are load-bearing and undocumented:

1. **`platform` must match exactly** between `login` and `refresh`. A mismatch
   revokes *every* session on the account. This is a footgun with no error
   message — worth stating loudly in the spec.
2. **OTP login returns no refresh token.** A session started via `login-otp`
   cannot be silently renewed and eventually forces a re-login. Users experience
   this as "the app randomly signs me out" without knowing why.
3. **Refresh tokens are single-use, rotated, and reuse is punished.** Confirmed
   against staging, not inferred. Every `POST /api/account/refresh` returns a
   *new* `refreshToken` and immediately invalidates the one presented. Sending a
   spent token returns:

   ```json
   { "statusCode": 403, "reason": "FORBIDDEN",
     "statusMessage": "Security alert: token reuse detected. All sessions have been terminated. Please log in again." }
   ```

   This is not a failed call — it destroys every session on the account. Two
   overlapping refreshes are enough to trigger it: firing three concurrently
   with the same token yields two 200s and one 403, and the account is then
   locked out until the user signs in again.

   **Recommendation:** document this loudly, and consider a short grace window
   in which the immediately-previous refresh token is accepted without being
   treated as theft. Rotation with reuse detection is the right design, but with
   a zero-tolerance window any client-side race — or simply a retried request on
   a flaky network — becomes a full sign-out. RFC 9700 §4.14.2 suggests exactly
   this allowance.

4. **Access tokens live exactly one hour**, and that is not documented anywhere.
   Any client doing proactive refresh has to pick a window shorter than the
   lifetime; a client that guesses "refresh within an hour of expiry" ends up
   refreshing before every single request, which combined with §1.5.3 is fatal.
   The lifetime should be stated in the spec, or better, returned as `expiresIn`
   alongside `expiresAt` so clients can size the window from the response.

### 1.7 An unverified account is indistinguishable from a wrong password

`POST /api/account/login` for an account that exists, has the **correct**
password, but has not verified its email returns:

```json
{ "statusCode": 401, "reason": "UNAUTHORIZED",
  "statusMessage": "The username or password is incorrect." }
```

— byte-identical to the response for a genuinely wrong password. The spec claims
a distinct `403 "Email not verified"` for this case (see the `oneOf` on
`/api/account/login`); the implementation does not produce it.

The consequence is a dead end: someone who has just signed up, typed their
password correctly, and not yet clicked through the verification email is told
their password is wrong, and nothing in the app can detect otherwise. The iOS
client now offers a "I haven't verified my email yet" route after *any* failed
sign-in, which is the best it can do blind.

**Recommendation:** return the documented `403` with a distinct message, or a
machine-readable `reason` such as `EMAIL_NOT_VERIFIED`. Note this is a
deliberate trade-off against account enumeration — but the account has already
been enumerated at registration time, so the leak is not new, and the usability
cost of hiding it is high. If enumeration is the concern, the `reason` field is
the right place for the distinction since it is only reachable with correct
credentials.

### 1.6 Delete semantics are asymmetric

`DELETE /api/todos/{id}` does something different depending on who calls it:

- **Owner deletes** → the list is gone for both people.
- **Partner deletes** → only their copy is removed; the owner is notified via
  `NOTIFICATION::LIST_DELETED`.

This is good behaviour, and completely invisible in the API. The native client
computes the difference locally to write an honest confirmation dialog
(`ListOptionsSheet.deleteWarning`). **Recommendation:** return the effect in the
response so clients don't have to infer it — e.g.
`{ "deletedFor": "both" | "self" }`.

---

## 2. Recommended API changes, by priority

### P0 — worth doing before the next client ships

0. **Add a grace window for the previous refresh token** (§1.5.3). This is the
   highest-severity item on the list: today a single overlapping refresh signs
   the user out of every device, and no client-side care can make a network
   retry safe.
1. **Distinguish "email not verified" from "wrong password"** at login (§1.7).
   Cheap to fix and removes a dead end for every new user.
2. **Real HTTP status codes** (`/api/v2`), as above.
3. **Regenerate the OpenAPI spec from the routes.** Fix the `priority` enum while
   you're there.
4. **Document the `platform` constraint, the token lifetime, and the OTP
   refresh-token gap.**

### P1 — removes whole classes of client complexity

4. **A single write endpoint per resource.**
   Updating a list currently takes five endpoints (`PUT /`, `/archive`,
   `/color`, `/priority`, `/deadline`) and each is a separate round trip. A
   `PATCH /api/todos/{id}` accepting any subset of fields would replace all of
   them. The same applies to todo items, which have `/done`, `/title`, and a
   catch-all `PUT`.

5. **Bulk reorder.**
   `PUT /api/todos/reorder/{listId}` moves one item. Dragging an item to the top
   of a 20-item list means 20 sequential requests — the native client does this
   today and it is the slowest interaction in the app. A single
   `PUT /api/todos/{listId}/order` taking `{ "todoIds": [...] }` fixes it.

6. **Delta sync / ETag on `GET /api/todos`.**
   Every foreground currently re-downloads every list with every item. Either
   `If-None-Match` support or `GET /api/todos?since=<timestamp>` would make
   refresh nearly free. This matters most on cellular and directly costs battery.

7. **Server-side pagination on `GET /api/notifications`.**
   The feed grows without bound and is fetched in full on every app launch.

### P2 — new capability

8. **APNs push.**
   Real-time delivery is Socket.IO only, which means a partner's change is
   invisible until the app is opened. Everything the socket emits already has a
   notification counterpart in the database — routing those through APNs (and
   FCM for Android) would let the app be genuinely useful while closed. This is
   the highest-value single addition on this list.

9. **A lightweight list endpoint for constrained clients.**
   `GET /api/todos` returns every list with every item and every field. The watch
   app needs roughly a fifth of that, and currently pays for the whole payload on
   cellular. A `?fields=compact` variant, or the delta sync in §2.6, would help
   watch battery life more than any client-side change could.

10. **Item-level location reminders in the UI.**
   `PATCH /api/todos/{listId}/items/{todoId}/location` exists and works; neither
   client exposes it. The iOS client is structured to add it cheaply — see
   §3.

11. **`GET /api/todos/nearby` is unused by both clients.**
    It returns lists whose geofence overlaps a point. Worth either building a
    "what's near me" feature on it or removing it.

12. **Web-socket event for alarms.**
    `NOTIFICATION::ALARM_FIRED` arrives, but the client has to re-fetch
    `/api/alarms` to learn what changed. Including the alarm object in the
    payload would remove the round trip.

13. **Consistent `updatedAt` on todo items.**
    The "Recently used" sort depends on it. It's present today but not
    documented, so it reads as incidental rather than guaranteed.

---

## 3. Suggested future updates to the iOS app

Ordered by value-to-effort. The architecture already accommodates all of these.

### Near-term

| Feature | Why | Where it slots in |
|---|---|---|
| **Widgets + Live Activities** | A shared list on the Home Screen is the single most requested feature for apps of this shape. A Live Activity during a shopping trip ("3 items left") is a natural fit with the geofence trigger. | New widget extension reading a shared App Group cache written by `AppStore`. |
| **App Intents / Siri** | "Add milk to the weekly shop" without opening the app. Also unlocks Shortcuts, the Action Button, and Spotlight. | `AppIntent` wrappers over `AppStore.addTodo` / `createList`. |
| **Offline queue** | Right now a failed write rolls back and tells the user. Queuing mutations and replaying them on reconnect would make the app usable on the Tube. | A `PendingMutation` log persisted alongside `TokenStore`; replay in `handleForeground`. |
| **Item-level location reminders** | The API already supports it (§2.9). "Remind me about *this one item* at the chemist." | `LocationPickerView` already takes a list; generalise to a target enum. |
| **Share Extension** | Send a link or a photo from another app straight into a list. | New extension target; posts through `APIClient.createTodo`. |

### Medium-term

| Feature | Why |
|---|---|
| **iPad and Mac Catalyst layout** | The project is already `TARGETED_DEVICE_FAMILY = 1,2`. A `NavigationSplitView` variant would make it a genuine iPad app rather than a stretched phone one. |
| **Watch complication / Smart Stack widget** | The watch app ships; the complication does not. Outstanding count and next deadline on the watch face is the highest-value remaining piece. Needs a new widget-extension target. |
| **Watch notifications with custom UI** | Deadline and geofence notifications already mirror to the watch. A custom long-look interface with a "Mark done" action would let them be dealt with from the wrist. |
| **More than two people per list** | The name says two, but `partnerId` being a single column is the only thing enforcing it. If the product ever wants small groups, this is the schema change to plan for. |
| **Passkeys** | The API's `social-login` flow already proves the server can verify third-party credentials. Passkeys would remove passwords entirely. |
| **Interactive widgets for ticking items off** | Depends on App Intents landing first. |

### Worth considering

- **Undo.** Deleting an item is currently permanent and immediate. A soft-delete
  window (client-side is enough) would remove the need for the confirmation on
  swipe-to-delete.
- **Smart list suggestions.** With `Foundation Models` on-device (iOS 26), the
  app could suggest items based on list history with no server cost and no data
  leaving the device.
- **Translation.** The app is English-only in both clients. String Catalogs are
  already enabled in the project (`LOCALIZATION_PREFERS_STRING_CATALOGS = YES`),
  so the groundwork is done.

---

## 4. Known limitations in this iOS client

Stated plainly so they don't come as surprises.

1. **Reorder is O(n) requests.** Blocked on API change §2.5.
2. **No offline writes.** Mutations fail and roll back when offline; reads fall
   back to whatever was last loaded.
3. **Geofences are capped at 20** by iOS. The client prioritises by soonest
   deadline, then most recently updated, and drops the rest. There is currently
   no UI telling the user this has happened.
4. **`aps-environment` is not in the entitlements.** The app has no remote push
   because the API has no APNs support (§2.8). Adding it is a one-line
   entitlement change plus a device-token registration call.
5. **Sign in with Apple needs portal configuration.** The entitlement file is in
   place; the capability must be enabled on the App ID
   (`com.afzaalahmadzeeshan.ios.twodos.twodos---ios`) before a device build will
   sign. Simulator builds work as-is.
6. **The watch has no complication.** See the roadmap above — it needs a widget
   extension target, which is best added through Xcode's own template.
7. **The watch cannot sign in.** By design: it takes its session from the phone,
   and holds no refresh token, so when the session expires it points at the phone
   rather than renewing.
8. **Analytics is absent by design.** No Firebase, no ATT prompt. If analytics
   returns, the natural seam is a protocol behind `AppStore`'s existing logging
   calls.
