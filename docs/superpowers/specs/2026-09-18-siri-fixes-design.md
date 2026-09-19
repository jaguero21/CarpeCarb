# Siri fixes (review #6–8) — design

Date: 2026-09-18 · Status: approved design, pending implementation plan

## Problem

Three bugs from the 2026-09-18 code review, all on the Siri / widget path:

- **#6 Siri stops working an hour after the app was last opened.** `LogFoodIntent`
  (`ios/Runner/CarbIntents.swift:6`) sends the Firebase ID token that the app copies
  into the Keychain and App Group UserDefaults (`lib/main.dart:62`,
  `lib/services/perplexity_firebase_service.dart:59`,
  `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift:38-42`). ID tokens expire
  after 1 hour, so Siri gets HTTP 401 unless the app ran recently.
- **#7 Siri and the widget don't know the day rolled over.** `CarbDataStore.addFood`
  adds to whatever total is stored (`CarbDataStore.swift:46`), so the first Siri
  log of the day reports yesterday's total plus the new item. `CheckCarbsIntent`
  (`CarbIntents.swift:29`) and the widget (`ios/CarbWiseWidget/CarbWiseWidget.swift:66`)
  show yesterday's total until the app is opened. "Today" (midnight, or the user's
  reset hour) is only known to Dart (`_todayString()`, `lib/main.dart:555`).
- **#8 Siri logs only the first item.** `PerplexityClient.lookupCarbs`
  (`PerplexityClient.swift:57`) keeps `items.first`; "burger and fries" logs the
  burger only.

## Facts the design relies on

- `CarbIntents.swift` is compiled into the Runner app target (not an extension), so
  App Intents run in the app's process, where FirebaseAuth is linked (Pods).
- FlutterFire's `firebase_core` configures the default `FIRApp` natively only if none
  exists (`FLTFirebaseCorePlugin.m`: `[FIRApp allApps][@"__FIRAPP_DEFAULT"] == nil`),
  so configuring it first from Swift is safe.
- Only the Runner target links the `CarbShared` package. The widget reads the App
  Group through its own `AppGroupConfig.swift`.
- The Watch app does not link `CarbShared` and is not embedded in `Runner.app`; it is
  out of scope and left untouched.

## Scope

In: #6, #7 (including the widget resetting at the day boundary), #8, plus three
approved extras: carry macros through Siri-logged items; remove the shared token
copies; send Siri items logged on an earlier day to Apple Health only.

Out: the Watch app; review #4, #5, #13 (iCloud sync) and others.

## Part 1 — one shared definition of "today"

- **`ios/CarbShared/Sources/CarbShared/CarbDay.swift` (new)**
  - `CarbDay.key(for date: Date, resetHour: Int, calendar: Calendar = .current) -> String`
    → `yyyy-MM-dd`. Mirrors Dart `_todayString()` exactly: if `resetHour > 0` and the
    local hour is `< resetHour`, the key is the previous calendar day.
  - `CarbDay.nextBoundary(after date: Date, resetHour: Int, calendar: Calendar = .current) -> Date`
    → the next instant at `resetHour:00` local time strictly after `date`.
- **`lib/utils/day_key.dart` (new)** — `String dayKey(DateTime now, int resetHour)`
  with the same rule; `_todayString()` returns `dayKey(DateTime.now(), resetHour)`.
- **New App Group keys** (written by the app via `HomeWidget.saveWidgetData`):
  `dayKey` (the day the stored totals belong to) and `dailyResetHour`.
- **`CarbDataStore` (CarbShared) becomes day-aware and injectable**
  - Backed by an injected `UserDefaults` (default: the App Group suite) so tests use a
    throwaway suite.
  - `snapshot(now: Date) -> CarbSnapshot` with `totalCarbs`, `lastFoodName`,
    `lastFoodCarbs`, `dailyGoal`. If the stored `dayKey` is present and differs from
    `CarbDay.key(for: now, resetHour: storedResetHour)`, total and last food are
    returned as 0 / empty; the goal is kept. A missing `dayKey` (pre-update build) is
    trusted as today; a missing `dailyResetHour` means 0 (midnight).
  - `addFood(_ item: LoggedFood, now: Date)` — starts from 0 when the stored day isn't
    today, writes the new total, last food, and `dayKey`, appends the item (name,
    carbs, macros, details, citations, `loggedAt`) to the `siriLoggedItems` buffer,
    and reloads widget timelines.
  - Mutating methods are `@MainActor` so the Siri intent and the app (same process)
    can't interleave read-modify-write on the App Group.
  - `totalCarbs()`, `lastFoodName()`, `lastFoodCarbs()`, `dailyCarbGoal()` and
    `firebaseIdToken()` are replaced by `snapshot(now:)` / removed.
- **Widget** — the `CarbWiseWidgetExtension` target links `CarbShared`. `loadData()`
  reads `CarbDataStore.snapshot(now:)`. The timeline has two entries: now, and
  `CarbDay.nextBoundary(after: now, resetHour:)` with totals zeroed, so the widget
  shows 0 at the boundary without the app running. Refresh policy stays
  `.after(15 min)`.

## Part 2 — Siri intents

- **`ios/Runner/SiriAuth.swift` (new, Runner target)** — `SiriAuth.idToken() async throws -> String`:
  on the main actor, `if FirebaseApp.app() == nil { FirebaseApp.configure() }`; then
  `Auth.auth().currentUser` → `try await user.getIDToken()` (refreshes when expired).
  No user → `IntentError.message("Open CarpeCarb once to finish setting up Siri.")`.
  Token failure → `IntentError.message("Couldn't reach CarpeCarb. Check your connection and try again.")`.
- **`PerplexityClient.lookupCarbs(for: String, idToken: String) async throws -> LookupResult`**
  (CarbShared stays Firebase-free). `LookupResult { items: [LookupItem], citations: [String] }`;
  `LookupItem { name, carbs, protein?, fat?, fiber?, calories?, details? }`. Parsing
  is a pure `static func parseResponse(_ data: Data) throws -> LookupResult`. An empty
  item list throws `IntentError.message("I couldn't find nutrition info for that.")`.
  Non-200 responses keep using `errorMessage(status:body:)` (daily quota etc.).
- **`LogFoodIntent`** — token → lookup → `CarbDataStore.addFood` per item → dialog
  from a pure `LogFoodDialog.text(items: [LookupItem], totalToday: Double) -> String`
  (CarbShared):
  - 1 item: "<name> has <c> grams of carbs. Your total today is <t> grams." (current wording)
  - 2–3 items: "Logged <n1>, <c1> grams, and <n2>, <c2> grams: <sum> grams. Your total today is <t> grams."
    (three items: "<n1>, <c1> grams, <n2>, <c2> grams, and <n3>, <c3> grams")
  - 4+ items: "Logged <count> items, <sum> grams. Your total today is <t> grams."
  - Numbers formatted as today (`%.1f` for item carbs and totals).
- **`CheckCarbsIntent`** — reads `CarbDataStore.snapshot(now:)`; wording unchanged
  (so on a new day it says nothing has been tracked today).
- **Token cleanup** — delete `ios/Runner/TokenStorageChannel.swift` and its
  registration (`AppDelegate.swift:9, 52-57`). `AppDelegate` removes the legacy
  `firebaseIdToken` entry from App Group UserDefaults and the Keychain once at launch
  (`KeychainHelper.delete`), so the plain-text copy doesn't linger on updated devices.

## Part 3 — Flutter

- `lib/config/storage_keys.dart`: add `widgetDayKey = 'dayKey'`,
  `widgetResetHour = 'dailyResetHour'`; remove `firebaseIdToken`, `tokenStorageChannel`.
- `_updateWidget()` (`main.dart:406`) and the new-day branch of `_loadSavedData()`
  (`main.dart:436`) also write today's `dayKey` and the reset hour. A reset-hour
  change in Settings already ends in `_updateWidget` via `_applySettingsResult`
  (`main.dart:1284`).
- **`lib/services/siri_import.dart` (new, pure)** —
  `SiriImport.parse(String json, DateTime now, int resetHour) -> ({List<FoodItem> today, List<FoodItem> earlier})`.
  Items carry macros. An item belongs to `earlier` when
  `dayKey(loggedAt, resetHour)` is before today's key; missing, unparseable, or future
  `loggedAt` → today. `_importSiriLoggedItems()` (`main.dart:480`) adds `today` to the
  list and Apple Health, sends `earlier` to Apple Health only (at their real time),
  then clears the buffer.
- Remove `_refreshSharedFirebaseToken()` and its call (`main.dart:55, 62`), and the
  `saveToken` call and `_tokenChannel` in `PerplexityFirebaseService` (lines 13, 59).

## Error handling (Siri)

| Situation | Spoken reply |
|---|---|
| No Firebase user yet | "Open CarpeCarb once to finish setting up Siri." |
| Token fetch failed | "Couldn't reach CarpeCarb. Check your connection and try again." |
| Daily quota / other server errors | existing `errorMessage(status:body:)` |
| No items returned | "I couldn't find nutrition info for that." |

## Testing

- **Swift Testing** (`ios/CarbShared/Tests/CarbSharedTests/`):
  - `CarbDay.key` / `nextBoundary` against a case table shared with Dart: reset hour 0
    and 4, either side of the boundary, a DST-change day.
  - `CarbDataStore` with a throwaway suite: new day starts from 0; missing `dayKey` is
    trusted; `snapshot` zeroes total and last food on a new day but keeps the goal;
    macros land in the Siri buffer.
  - `PerplexityClient.parseResponse`: multiple items, macros, empty list.
  - `LogFoodDialog.text` for 1, 2, 3 and 4+ items.
- **Dart**: `test/day_key_test.dart` with the same case table;
  `test/siri_import_test.dart` for the today/earlier split, macros, and missing
  timestamps.
- **Build**: `xcodebuild` Runner scheme (widget now links CarbShared); built app and
  widget versions match.
- **Manual (device)**: Siri logs food after more than an hour without opening the
  app; the next morning "Check my carbs" reports nothing yet and the widget shows 0
  after the reset hour; "burger and fries" logs two items; a Siri item logged
  yesterday appears in Apple Health but not in today's list.
