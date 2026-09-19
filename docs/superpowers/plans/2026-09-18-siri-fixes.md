# Siri Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Siri work without the app having run in the last hour, keep Siri/widget totals correct across day boundaries, log every item of a multi-item lookup, and stop storing copies of the Firebase token.

**Architecture:** A shared definition of "today" (`CarbDay.key` in Swift, `dayKey` in Dart, same rule, same test table) plus a `dayKey` written to the App Group lets Siri and the widget detect stale totals. Siri intents run in the app process, so they get a fresh Firebase ID token from Firebase Auth directly (`SiriAuth`), pass it into the Firebase-free `CarbShared` package, and log every item. The app imports Siri items split by day.

**Tech Stack:** Swift 6.4 toolchain (package in Swift 5 mode), Swift Testing, App Intents, WidgetKit, FirebaseAuth (iOS SDK via CocoaPods); Flutter 3.41 / Dart 3.11, `flutter_test`, `home_widget`.

**Spec:** `docs/superpowers/specs/2026-09-18-siri-fixes-design.md`

## Global Constraints

- Commits carry NO `Co-Authored-By` or other attribution trailer. Explicit `git add` paths only.
- Branch: `feature/siri-fixes` (the spec is already committed there).
- Day rule (both languages): the day starts at `resetHour` (0 = midnight); hours before it belong to the previous calendar day, computed with calendar arithmetic (never "minus 24 hours"). Key format `yyyy-MM-dd`.
- New App Group keys: `dayKey`, `dailyResetHour`. A missing `dayKey` is trusted as today; a missing `dailyResetHour` means 0.
- Siri replies, verbatim: "Open CarpeCarb once to finish setting up Siri." / "Couldn't reach CarpeCarb. Check your connection and try again." / "I couldn't find nutrition info for that."
- `CarbShared` stays free of Firebase; the ID token is passed in.
- No force unwraps / `try!` in shipped Swift code.
- The Watch app targets are out of scope; don't edit them.
- `project.pbxproj` edits are done with the exact scripts given (they assert each anchor appears exactly once and end with `plutil -lint`).
- iOS build check (from the repo root): `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. Expected third-party output that is not yours to fix: an `in_app_purchase_storekit` header deprecation warning and two `libtool: warning: '…' has no symbols` lines.

## File Map

| File | Status | Responsibility |
|---|---|---|
| `ios/CarbShared/Sources/CarbShared/CarbDay.swift` | create | `CarbDay.key`, `CarbDay.nextBoundary` |
| `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift` | rewrite | day-aware App Group store: `CarbSnapshot`, `LoggedFood`, `CarbDataStore.shared`, `snapshot(now:)`, `addFood(_:now:)` |
| `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift` | rewrite | `LookupItem`, `LookupResult`, `lookupCarbs(for:idToken:)`, `parseResponse(_:)`, `errorMessage(status:body:)` |
| `ios/CarbShared/Sources/CarbShared/LogFoodDialog.swift` | create | Siri's reply after logging |
| `ios/CarbShared/Tests/CarbSharedTests/*.swift` | create/extend | Swift Testing suites |
| `ios/Runner/SiriAuth.swift` | create | fresh Firebase ID token for intents |
| `ios/Runner/CarbIntents.swift` | rewrite | `LogFoodIntent`, `CheckCarbsIntent`, `OpenCarpeCarbIntent` |
| `ios/Runner/AppDelegate.swift` | modify | drop TokenStorageChannel; remove legacy token copies at launch |
| `ios/Runner/TokenStorageChannel.swift` | delete | |
| `ios/CarbWiseWidget/CarbWiseWidget.swift` | modify | day-aware data + day-boundary timeline entry |
| `ios/CarbShared.swift`, `ios/CarbWiseWidget/CarbShared.swift` | delete | dead duplicates (in no target) of an old CarbShared |
| `ios/Runner.xcodeproj/project.pbxproj` | modify | add SiriAuth.swift; link CarbShared into the widget; remove TokenStorageChannel.swift |
| `lib/utils/day_key.dart` | create | Dart twin of `CarbDay.key` |
| `lib/services/siri_import.dart` | create | parse + split the Siri buffer by day |
| `lib/main.dart` | modify | `_todayString` → `dayKey`; write `dayKey`/reset hour; new Siri import; remove token copy |
| `lib/config/storage_keys.dart` | modify | add `widgetDayKey`, `widgetResetHour`; remove token keys |
| `lib/services/perplexity_firebase_service.dart` | modify | remove token copy |
| `test/day_key_test.dart`, `test/siri_import_test.dart` | create | Dart tests |

---

### Task 1: One shared definition of "today"

**Files:**
- Create: `ios/CarbShared/Sources/CarbShared/CarbDay.swift`, `lib/utils/day_key.dart`
- Test: `ios/CarbShared/Tests/CarbSharedTests/CarbDayTests.swift`, `test/day_key_test.dart`
- Modify: `lib/main.dart` (`_todayString`, imports)

**Interfaces:**
- Produces (Swift): `CarbDay.key(for date: Date, resetHour: Int, calendar: Calendar = .current) -> String`; `CarbDay.nextBoundary(after date: Date, resetHour: Int, calendar: Calendar = .current) -> Date`.
- Produces (Dart): `String dayKey(DateTime now, int resetHour)` in `lib/utils/day_key.dart`.

- [ ] **Step 1: Write the failing Swift test**

Create `ios/CarbShared/Tests/CarbSharedTests/CarbDayTests.swift`:

```swift
import Foundation
import Testing
@testable import CarbShared

// Same cases as test/day_key_test.dart (the Dart twin of CarbDay.key).
struct CarbDayTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test(arguments: [
        (2026, 9, 18, 0, 0, 0, "2026-09-18"),   // midnight reset, start of day
        (2026, 9, 18, 23, 59, 0, "2026-09-18"), // midnight reset, end of day
        (2026, 9, 18, 3, 59, 4, "2026-09-17"),  // before a 4 AM reset → previous day
        (2026, 9, 18, 4, 0, 4, "2026-09-18"),   // at the reset hour → same day
        (2026, 3, 1, 2, 0, 4, "2026-02-28"),    // month boundary
        (2026, 1, 1, 0, 30, 4, "2025-12-31"),   // year boundary
        (2026, 3, 9, 0, 30, 4, "2026-03-08"),   // day after DST starts (23-hour day)
    ])
    func key(y: Int, m: Int, d: Int, h: Int, min: Int, resetHour: Int, expected: String) {
        #expect(CarbDay.key(for: date(y, m, d, h, min), resetHour: resetHour, calendar: calendar) == expected)
    }

    @Test func nextBoundaryIsNextMidnightWithNoResetHour() {
        let next = CarbDay.nextBoundary(after: date(2026, 9, 18, 21, 15), resetHour: 0, calendar: calendar)
        #expect(next == date(2026, 9, 19, 0, 0))
    }

    @Test func nextBoundaryIsLaterTodayBeforeTheResetHour() {
        let next = CarbDay.nextBoundary(after: date(2026, 9, 18, 2, 0), resetHour: 4, calendar: calendar)
        #expect(next == date(2026, 9, 18, 4, 0))
    }

    @Test func nextBoundaryAtTheResetHourIsTomorrow() {
        let next = CarbDay.nextBoundary(after: date(2026, 9, 18, 4, 0), resetHour: 4, calendar: calendar)
        #expect(next == date(2026, 9, 19, 4, 0))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ios/CarbShared && swift test --filter CarbDayTests`
Expected: compile error `cannot find 'CarbDay' in scope`.

- [ ] **Step 3: Implement `CarbDay`**

Create `ios/CarbShared/Sources/CarbShared/CarbDay.swift`:

```swift
import Foundation

/// The app's notion of "today": a calendar day that starts at `resetHour`
/// (0 = midnight). Mirrors `dayKey` in lib/utils/day_key.dart; both are tested
/// against the same cases, so change them together.
public enum CarbDay {
    /// `yyyy-MM-dd` of the day `date` belongs to. Hours before `resetHour`
    /// count as the previous calendar day.
    public static func key(for date: Date, resetHour: Int, calendar: Calendar = .current) -> String {
        var day = date
        if resetHour > 0, calendar.component(.hour, from: date) < resetHour,
           let previous = calendar.date(byAdding: .day, value: -1, to: date) {
            day = previous
        }
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The next instant after `date` when the day changes (`resetHour`:00 local time).
    public static func nextBoundary(after date: Date, resetHour: Int, calendar: Calendar = .current) -> Date {
        let boundary = DateComponents(hour: resetHour, minute: 0, second: 0)
        return calendar.nextDate(after: date, matching: boundary, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(24 * 60 * 60)
    }
}
```

- [ ] **Step 4: Run the Swift tests**

Run: `cd ios/CarbShared && swift test`
Expected: `✔ Test run with 8 tests in 2 suites passed` (4 existing + 4 new; the parameterized `key` test runs 7 cases).

- [ ] **Step 5: Write the failing Dart test**

Create `test/day_key_test.dart` (same cases as the Swift table):

```dart
import 'package:carb_tracker/utils/day_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Same cases as CarbDayTests.swift (the Swift twin used by Siri and the widget).
  final cases = <(DateTime, int, String, String)>[
    (DateTime(2026, 9, 18, 0, 0), 0, '2026-09-18', 'midnight reset, start of day'),
    (DateTime(2026, 9, 18, 23, 59), 0, '2026-09-18', 'midnight reset, end of day'),
    (DateTime(2026, 9, 18, 3, 59), 4, '2026-09-17', 'before a 4 AM reset: previous day'),
    (DateTime(2026, 9, 18, 4, 0), 4, '2026-09-18', 'at the reset hour: same day'),
    (DateTime(2026, 3, 1, 2, 0), 4, '2026-02-28', 'month boundary'),
    (DateTime(2026, 1, 1, 0, 30), 4, '2025-12-31', 'year boundary'),
    (DateTime(2026, 3, 9, 0, 30), 4, '2026-03-08', 'day after DST starts (23-hour day)'),
  ];

  for (final (now, resetHour, expected, label) in cases) {
    test('dayKey: $label', () {
      expect(dayKey(now, resetHour), expected);
    });
  }
}
```

Run: `flutter test test/day_key_test.dart`
Expected: FAIL to compile, `utils/day_key.dart` doesn't exist.

- [ ] **Step 6: Implement `dayKey`**

Create `lib/utils/day_key.dart`:

```dart
/// The app's calendar day as `YYYY-MM-DD`. A day starts at [resetHour]
/// (0 = midnight), so earlier hours belong to the previous day.
///
/// Mirrors `CarbDay.key` in ios/CarbShared/Sources/CarbShared/CarbDay.swift,
/// which Siri and the widget use; both are tested against the same cases, so
/// change them together. Uses calendar arithmetic (not "minus 24 hours") so the
/// day after a daylight-saving change still maps to the right date.
String dayKey(DateTime now, int resetHour) {
  final day = (resetHour > 0 && now.hour < resetHour)
      ? DateTime(now.year, now.month, now.day - 1)
      : now;
  final y = day.year.toString().padLeft(4, '0');
  final m = day.month.toString().padLeft(2, '0');
  final d = day.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
```

- [ ] **Step 7: Use it in `main.dart`**

Add the import after `import 'utils/date_format.dart';`:

```dart
import 'utils/day_key.dart';
```

Replace `_todayString()`:

```dart
  String _todayString() {
    var now = DateTime.now();
    // If before the reset hour, treat it as the previous day
    if (resetHour > 0 && now.hour < resetHour) {
      now = now.subtract(const Duration(days: 1));
    }
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
```

with:

```dart
  String _todayString() => dayKey(DateTime.now(), resetHour);
```

(The old "minus 24 hours" returned the wrong date the day after a daylight-saving change; the DST case in the table covers it.)

- [ ] **Step 8: Run the Dart checks**

Run: `flutter analyze && flutter test`
Expected: `No issues found!`, then `All tests passed!` (72 tests).

- [ ] **Step 9: Commit**

```bash
git add ios/CarbShared/Sources/CarbShared/CarbDay.swift ios/CarbShared/Tests/CarbSharedTests/CarbDayTests.swift lib/utils/day_key.dart test/day_key_test.dart lib/main.dart
git commit -m "feat: one shared definition of today for Swift and Dart"
```

---

### Task 2: Siri gets a fresh token, logs every item, and knows the day

**Files:**
- Rewrite: `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift`, `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift`, `ios/Runner/CarbIntents.swift`
- Create: `ios/CarbShared/Sources/CarbShared/LogFoodDialog.swift`, `ios/Runner/SiriAuth.swift`
- Modify: `ios/Runner.xcodeproj/project.pbxproj` (add SiriAuth.swift to Runner)
- Test: create `ios/CarbShared/Tests/CarbSharedTests/CarbDataStoreTests.swift`, `ios/CarbShared/Tests/CarbSharedTests/LogFoodDialogTests.swift`; append to `ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift`

**Interfaces:**
- Consumes: `CarbDay.key` (Task 1).
- Produces:
  - `CarbSnapshot(totalCarbs: Double, lastFoodName: String, lastFoodCarbs: Double, dailyGoal: Double?)`, `var startingNewDay: CarbSnapshot`.
  - `LoggedFood(name:carbs:protein:fat:fiber:calories:details:citations:)` (optionals default nil, citations default `[]`); `LoggedFood(item: LookupItem, citations: [String])`.
  - `CarbDataStore.shared`, `CarbDataStore(defaults: UserDefaults?)`, `CarbDataStore.appGroupID`, `CarbDataStore.Keys.{totalCarbs,lastFoodName,lastFoodCarbs,dailyCarbGoal,siriLoggedItems,dayKey,dailyResetHour,flutterTotalCarbs}`, `var resetHour: Int`, `func snapshot(now: Date = Date()) -> CarbSnapshot`, `@MainActor func addFood(_ food: LoggedFood, now: Date = Date())`.
  - `LookupItem(name:carbs:protein:fat:fiber:calories:details:)`, `LookupResult(items: [LookupItem], citations: [String])`, `PerplexityClient.lookupCarbs(for: String, idToken: String) async throws -> LookupResult`, `static func parseResponse(_ data: Data) throws -> LookupResult` (internal).
  - `LogFoodDialog.text(items: [LookupItem], totalToday: Double) -> String`.
  - `SiriAuth.idToken() async throws -> String` (Runner target).
  - Removed: `CarbDataStore.totalCarbs()`, `.lastFoodName()`, `.lastFoodCarbs()`, `.dailyCarbGoal()`, `.firebaseIdToken()`, `.addFood(name:carbs:details:citations:)`.

- [ ] **Step 1: Write the failing store test**

Create `ios/CarbShared/Tests/CarbSharedTests/CarbDataStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import CarbShared

@MainActor
struct CarbDataStoreTests {
    private let suiteName = "CarbDataStoreTests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let store: CarbDataStore
    private let noon: Date

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        store = CarbDataStore(defaults: defaults)
        noon = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12)))
    }

    private func seedYesterday() {
        defaults.set(80.0, forKey: CarbDataStore.Keys.totalCarbs)
        defaults.set("Pasta", forKey: CarbDataStore.Keys.lastFoodName)
        defaults.set(60.0, forKey: CarbDataStore.Keys.lastFoodCarbs)
        defaults.set(150.0, forKey: CarbDataStore.Keys.dailyCarbGoal)
        defaults.set("2026-09-17", forKey: CarbDataStore.Keys.dayKey)
    }

    @Test func snapshotOfTodaysTotals() {
        seedYesterday()
        defaults.set("2026-09-18", forKey: CarbDataStore.Keys.dayKey)
        #expect(store.snapshot(now: noon) == CarbSnapshot(totalCarbs: 80, lastFoodName: "Pasta", lastFoodCarbs: 60, dailyGoal: 150))
    }

    @Test func snapshotOnANewDayIsEmptyButKeepsTheGoal() {
        seedYesterday()
        #expect(store.snapshot(now: noon) == CarbSnapshot(totalCarbs: 0, lastFoodName: "", lastFoodCarbs: 0, dailyGoal: 150))
    }

    @Test func missingDayKeyIsTrustedAsToday() {
        seedYesterday()
        defaults.removeObject(forKey: CarbDataStore.Keys.dayKey)
        #expect(store.snapshot(now: noon).totalCarbs == 80)
    }

    @Test func resetHourMovesTheDayBoundary() throws {
        seedYesterday()
        defaults.set(4, forKey: CarbDataStore.Keys.dailyResetHour)
        let threeAM = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 3)))
        #expect(store.snapshot(now: threeAM).totalCarbs == 80) // still "2026-09-17" before 4 AM
        #expect(store.snapshot(now: noon).totalCarbs == 0)
    }

    @Test func addFoodOnANewDayStartsFromZeroAndStampsToday() {
        seedYesterday()
        store.addFood(LoggedFood(name: "Apple", carbs: 25), now: noon)
        #expect(store.snapshot(now: noon).totalCarbs == 25)
        #expect(defaults.string(forKey: CarbDataStore.Keys.dayKey) == "2026-09-18")
    }

    @Test func addFoodAddsToTodaysTotal() {
        store.addFood(LoggedFood(name: "Apple", carbs: 25), now: noon)
        store.addFood(LoggedFood(name: "Fries", carbs: 48), now: noon)
        #expect(store.snapshot(now: noon) == CarbSnapshot(totalCarbs: 73, lastFoodName: "Fries", lastFoodCarbs: 48, dailyGoal: nil))
    }

    @Test func addFoodBuffersItemsWithMacrosForTheApp() {
        store.addFood(LoggedFood(name: "Big Mac", carbs: 45, protein: 25, fat: 30, fiber: 3, calories: 590,
                                 details: "McDonald's", citations: ["https://example.com"]), now: noon)
        store.addFood(LoggedFood(name: "Water", carbs: 0), now: noon)
        let buffer = store.siriLoggedItems()
        #expect(buffer.count == 2)
        #expect(buffer[0]["name"] as? String == "Big Mac")
        #expect(buffer[0]["protein"] as? Double == 25)
        #expect(buffer[0]["calories"] as? Double == 590)
        #expect(buffer[0]["citations"] as? [String] == ["https://example.com"])
        #expect(buffer[0]["loggedAt"] as? String == ISO8601DateFormatter().string(from: noon))
        #expect(buffer[1]["protein"] == nil)
    }
}
```

- [ ] **Step 2: Write the failing parser and dialog tests**

Append to `ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift` (after the existing `PerplexityClientErrorMessageTests`):

```swift
struct PerplexityClientParseTests {
    private func body(_ result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["result": result])
    }

    @Test func parsesEveryItemWithMacros() throws {
        let data = try body([
            "items": [
                ["name": "Big Mac", "carbs": 45, "protein": 25, "fat": 30, "fiber": 3, "calories": 590, "details": "McDonald's [1]"],
                ["name": "Fries", "carbs": "48", "protein": NSNull()],
            ],
            "citations": ["https://example.com"],
        ])
        let result = try PerplexityClient.parseResponse(data)
        #expect(result == LookupResult(items: [
            LookupItem(name: "Big Mac", carbs: 45, protein: 25, fat: 30, fiber: 3, calories: 590, details: "McDonald's [1]"),
            LookupItem(name: "Fries", carbs: 48),
        ], citations: ["https://example.com"]))
    }

    @Test func emptyItemsSaysNothingWasFound() throws {
        let data = try body(["items": [] as [Any]])
        #expect(throws: IntentError.self) { try PerplexityClient.parseResponse(data) }
        do {
            _ = try PerplexityClient.parseResponse(data)
        } catch let IntentError.message(message) {
            #expect(message == "I couldn't find nutrition info for that.")
        }
    }

    @Test func malformedBodyIsAParseError() {
        #expect(throws: IntentError.self) { try PerplexityClient.parseResponse(Data("oops".utf8)) }
    }
}
```

Create `ios/CarbShared/Tests/CarbSharedTests/LogFoodDialogTests.swift`:

```swift
import Testing
@testable import CarbShared

struct LogFoodDialogTests {
    private let bigMac = LookupItem(name: "Big Mac", carbs: 45)
    private let fries = LookupItem(name: "fries", carbs: 48)
    private let coke = LookupItem(name: "Coke", carbs: 39)

    @Test func oneItemKeepsTheOriginalWording() {
        #expect(LogFoodDialog.text(items: [bigMac], totalToday: 88) ==
            "Big Mac has 45.0 grams of carbs. Your total today is 88.0 grams.")
    }

    @Test func twoItemsAreListed() {
        #expect(LogFoodDialog.text(items: [bigMac, fries], totalToday: 136) ==
            "Logged Big Mac, 45.0 grams, and fries, 48.0 grams: 93.0 grams. Your total today is 136.0 grams.")
    }

    @Test func threeItemsAreListed() {
        #expect(LogFoodDialog.text(items: [bigMac, fries, coke], totalToday: 132) ==
            "Logged Big Mac, 45.0 grams, fries, 48.0 grams, and Coke, 39.0 grams: 132.0 grams. Your total today is 132.0 grams.")
    }

    @Test func fourOrMoreItemsAreCounted() {
        #expect(LogFoodDialog.text(items: [bigMac, fries, coke, bigMac], totalToday: 177) ==
            "Logged 4 items, 177.0 grams. Your total today is 177.0 grams.")
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `cd ios/CarbShared && swift test`
Expected: compile errors such as `cannot find 'CarbSnapshot' in scope`, `cannot find 'LookupItem' in scope`, `cannot find 'LogFoodDialog' in scope`.

- [ ] **Step 4: Rewrite `CarbDataStore.swift`**

Replace `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift`:

```swift
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Today's totals as Siri and the widget should show them.
public struct CarbSnapshot: Equatable, Sendable {
    public let totalCarbs: Double
    public let lastFoodName: String
    public let lastFoodCarbs: Double
    public let dailyGoal: Double?

    public init(totalCarbs: Double, lastFoodName: String, lastFoodCarbs: Double, dailyGoal: Double?) {
        self.totalCarbs = totalCarbs
        self.lastFoodName = lastFoodName
        self.lastFoodCarbs = lastFoodCarbs
        self.dailyGoal = dailyGoal
    }

    /// The same snapshot at the start of a new day: nothing logged yet, goal kept.
    public var startingNewDay: CarbSnapshot {
        CarbSnapshot(totalCarbs: 0, lastFoodName: "", lastFoodCarbs: 0, dailyGoal: dailyGoal)
    }
}

/// A food logged outside the app (Siri), buffered for the app to import.
public struct LoggedFood: Equatable, Sendable {
    public let name: String
    public let carbs: Double
    public let protein: Double?
    public let fat: Double?
    public let fiber: Double?
    public let calories: Double?
    public let details: String?
    public let citations: [String]

    public init(name: String, carbs: Double, protein: Double? = nil, fat: Double? = nil,
                fiber: Double? = nil, calories: Double? = nil, details: String? = nil,
                citations: [String] = []) {
        self.name = name
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.fiber = fiber
        self.calories = calories
        self.details = details
        self.citations = citations
    }
}

/// The App Group store shared by the app (via HomeWidget), Siri, and the widget.
///
/// The app writes the totals together with the day they belong to (`dayKey`)
/// and the user's reset hour, so readers can tell when the stored totals are
/// from a previous day.
public struct CarbDataStore {
    public static let appGroupID = "group.com.carpecarb.shared"

    /// UserDefaults key constants — must match StorageKeys in Dart.
    public struct Keys {
        public static let totalCarbs = "totalCarbs"
        public static let lastFoodName = "lastFoodName"
        public static let lastFoodCarbs = "lastFoodCarbs"
        public static let dailyCarbGoal = "dailyCarbGoal"
        public static let siriLoggedItems = "siriLoggedItems"
        public static let dayKey = "dayKey"
        public static let dailyResetHour = "dailyResetHour"
        public static let flutterTotalCarbs = "flutter.total_carbs"
    }

    /// The App Group store used by the app, Siri, and the widget.
    public static let shared = CarbDataStore(defaults: UserDefaults(suiteName: appGroupID))

    private let defaults: UserDefaults?

    /// - Parameter defaults: the backing store; tests pass a throwaway suite.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// Hour the user's day starts at (0 = midnight). Missing means 0.
    public var resetHour: Int {
        defaults?.integer(forKey: Keys.dailyResetHour) ?? 0
    }

    /// Today's totals. If the stored totals belong to an earlier day, total and
    /// last food are empty; the goal is kept. A missing `dayKey` (written by an
    /// app build from before day tracking) is trusted as today.
    public func snapshot(now: Date = Date()) -> CarbSnapshot {
        let goal = defaults?.double(forKey: Keys.dailyCarbGoal) ?? 0
        let stored = CarbSnapshot(
            totalCarbs: defaults?.double(forKey: Keys.totalCarbs) ?? 0,
            lastFoodName: defaults?.string(forKey: Keys.lastFoodName) ?? "",
            lastFoodCarbs: defaults?.double(forKey: Keys.lastFoodCarbs) ?? 0,
            dailyGoal: goal > 0 ? goal : nil
        )
        return isStoredDayCurrent(now: now) ? stored : stored.startingNewDay
    }

    /// Adds a food logged outside the app: updates today's totals (starting
    /// from 0 on a new day), stamps today's `dayKey`, and appends the item to
    /// the buffer the app imports on its next launch or resume.
    ///
    /// Main-actor isolated: Siri runs in the app's process, so this keeps its
    /// read-modify-write from interleaving with the app's own App Group writes.
    @MainActor
    public func addFood(_ food: LoggedFood, now: Date = Date()) {
        let newTotal = snapshot(now: now).totalCarbs + food.carbs
        defaults?.set(newTotal, forKey: Keys.totalCarbs)
        defaults?.set(food.name, forKey: Keys.lastFoodName)
        defaults?.set(food.carbs, forKey: Keys.lastFoodCarbs)
        defaults?.set(CarbDay.key(for: now, resetHour: resetHour), forKey: Keys.dayKey)
        defaults?.set(newTotal, forKey: Keys.flutterTotalCarbs)

        var buffer = siriLoggedItems()
        var entry: [String: Any] = [
            "name": food.name,
            "carbs": food.carbs,
            "loggedAt": ISO8601DateFormatter().string(from: now),
        ]
        if let protein = food.protein { entry["protein"] = protein }
        if let fat = food.fat { entry["fat"] = fat }
        if let fiber = food.fiber { entry["fiber"] = fiber }
        if let calories = food.calories { entry["calories"] = calories }
        if let details = food.details { entry["details"] = details }
        if !food.citations.isEmpty { entry["citations"] = food.citations }
        buffer.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: buffer),
           let json = String(data: data, encoding: .utf8) {
            defaults?.set(json, forKey: Keys.siriLoggedItems)
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Items waiting for the app to import, as written by `addFood`.
    func siriLoggedItems() -> [[String: Any]] {
        guard let json = defaults?.string(forKey: Keys.siriLoggedItems),
              let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items
    }

    private func isStoredDayCurrent(now: Date) -> Bool {
        guard let storedDay = defaults?.string(forKey: Keys.dayKey) else { return true }
        return storedDay == CarbDay.key(for: now, resetHour: resetHour)
    }
}
```

- [ ] **Step 5: Rewrite `PerplexityClient.swift`**

Replace `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift` (keeps `errorMessage(status:body:)` unchanged; removes the `URL(string:)!` force unwrap):

```swift
import Foundation

/// One food from a carb lookup.
public struct LookupItem: Equatable, Sendable {
    public let name: String
    public let carbs: Double
    public let protein: Double?
    public let fat: Double?
    public let fiber: Double?
    public let calories: Double?
    public let details: String?

    public init(name: String, carbs: Double, protein: Double? = nil, fat: Double? = nil,
                fiber: Double? = nil, calories: Double? = nil, details: String? = nil) {
        self.name = name
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.fiber = fiber
        self.calories = calories
        self.details = details
    }
}

/// Every food the server found for one lookup ("burger and fries" → 2 items).
public struct LookupResult: Equatable, Sendable {
    public let items: [LookupItem]
    public let citations: [String]

    public init(items: [LookupItem], citations: [String]) {
        self.items = items
        self.citations = citations
    }
}

extension LoggedFood {
    /// The buffered form of a looked-up item, keeping its macros.
    public init(item: LookupItem, citations: [String]) {
        self.init(name: item.name, carbs: item.carbs, protein: item.protein, fat: item.fat,
                  fiber: item.fiber, calories: item.calories, details: item.details,
                  citations: citations)
    }
}

public struct PerplexityClient {
    private static var lastRequestTime: Date?
    private static let minInterval: TimeInterval = 1.5

    // Firebase Cloud Function endpoint
    private static let cloudFunctionURL = "https://us-central1-carpecarb.cloudfunctions.net/getMultipleCarbCounts"

    private static func enforceRateLimit() async {
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }

    /// Looks up every food in `foodItem` via the Cloud Function.
    ///
    /// - Parameter idToken: a current Firebase ID token for the signed-in user.
    ///   CarbShared stays free of Firebase, so the caller supplies it.
    public static func lookupCarbs(for foodItem: String, idToken: String) async throws -> LookupResult {
        await enforceRateLimit()

        guard let url = URL(string: cloudFunctionURL) else {
            throw IntentError.message("Invalid server address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "data": [
                "input": foodItem,
                // Lets the server count the free quota per local calendar day.
                "tzOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            ] as [String: Any]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntentError.message("Invalid response from server.")
        }

        guard httpResponse.statusCode == 200 else {
            throw IntentError.message(errorMessage(status: httpResponse.statusCode, body: data))
        }

        return try parseResponse(data)
    }

    /// Parses a 200 response. Firebase callable functions wrap it in
    /// `{"result": {"items": [...], "citations": [...]}}`.
    static func parseResponse(_ data: Data) throws -> LookupResult {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let rawItems = result["items"] as? [[String: Any]] else {
            throw IntentError.message("Could not parse server response.")
        }

        let items = rawItems.map { raw in
            LookupItem(
                name: raw["name"] as? String ?? "Unknown",
                carbs: number(raw["carbs"]) ?? 0,
                protein: number(raw["protein"]),
                fat: number(raw["fat"]),
                fiber: number(raw["fiber"]),
                calories: number(raw["calories"]),
                details: raw["details"] as? String
            )
        }
        guard !items.isEmpty else {
            throw IntentError.message("I couldn't find nutrition info for that.")
        }
        return LookupResult(items: items, citations: result["citations"] as? [String] ?? [])
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Maps a non-200 response from the callable function to a message Siri
    /// can speak. Callable errors have the body
    /// `{"error": {"message", "status", "details"}}`.
    static func errorMessage(status: Int, body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let details = (json?["error"] as? [String: Any])?["details"] as? [String: Any]

        if status == 429, details?["reason"] as? String == "daily-quota" {
            let limit = (details?["limit"] as? NSNumber)?.intValue
            let count = limit.map { "\($0) " } ?? ""
            return "You've used today's \(count)free lookups. Open CarpeCarb to go unlimited."
        }
        if status == 429 {
            return "Rate limit exceeded. Try again shortly."
        }
        return "Server error (\(status))."
    }
}
```

- [ ] **Step 6: Add `LogFoodDialog.swift`**

Create `ios/CarbShared/Sources/CarbShared/LogFoodDialog.swift`:

```swift
import Foundation

/// What Siri says after logging food.
public enum LogFoodDialog {
    public static func text(items: [LookupItem], totalToday: Double) -> String {
        let total = "Your total today is \(grams(totalToday)) grams."
        let sum = items.reduce(0) { $0 + $1.carbs }
        switch items.count {
        case 1:
            return "\(items[0].name) has \(grams(items[0].carbs)) grams of carbs. \(total)"
        case 2:
            // Each part already contains a comma ("fries, 48.0 grams"), so a comma
            // before "and" keeps the two parts distinct when spoken.
            return "Logged \(part(items[0])), and \(part(items[1])): \(grams(sum)) grams. \(total)"
        case 3:
            return "Logged \(part(items[0])), \(part(items[1])), and \(part(items[2])): \(grams(sum)) grams. \(total)"
        default:
            return "Logged \(items.count) items, \(grams(sum)) grams. \(total)"
        }
    }

    private static func part(_ item: LookupItem) -> String {
        "\(item.name), \(grams(item.carbs)) grams"
    }

    private static func grams(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
```

- [ ] **Step 7: Run the package tests**

Run: `cd ios/CarbShared && swift test`
Expected: `✔ Test run with 22 tests in 5 suites passed`.

- [ ] **Step 8: Add `SiriAuth.swift` to the Runner target**

Create `ios/Runner/SiriAuth.swift`:

```swift
import CarbShared
import FirebaseAuth
import FirebaseCore

/// Gets a Firebase ID token for Siri requests.
///
/// App Intents in the Runner target run inside the app's process, so they can
/// use Firebase Auth directly. `getIDToken()` refreshes the token when it has
/// expired (ID tokens last one hour), which the old shared-token copy couldn't.
enum SiriAuth {
    static func idToken() async throws -> String {
        let user = await MainActor.run { () -> User? in
            // A background Siri launch may not start the Flutter engine, so
            // configure Firebase here if FlutterFire hasn't yet. FlutterFire
            // skips its own setup when a default app already exists.
            if FirebaseApp.app() == nil {
                FirebaseApp.configure()
            }
            return Auth.auth().currentUser
        }
        guard let user else {
            throw IntentError.message("Open CarpeCarb once to finish setting up Siri.")
        }
        do {
            return try await user.getIDToken()
        } catch {
            throw IntentError.message("Couldn't reach CarpeCarb. Check your connection and try again.")
        }
    }
}
```

Register it in the Xcode project (same group and Sources phase as `CarbIntents.swift`), from the repo root:

```bash
python3 - <<'EOF'
p = "ios/Runner.xcodeproj/project.pbxproj"; s = open(p).read()
edits = [
 ("\t\tSI0001B2 /* CarpeCarbShortcuts.swift in Sources */ = {isa = PBXBuildFile; fileRef = SI0001A2 /* CarpeCarbShortcuts.swift */; };\n",
  "\t\tSI0001B2 /* CarpeCarbShortcuts.swift in Sources */ = {isa = PBXBuildFile; fileRef = SI0001A2 /* CarpeCarbShortcuts.swift */; };\n\t\tSI0001B3 /* SiriAuth.swift in Sources */ = {isa = PBXBuildFile; fileRef = SI0001A3 /* SiriAuth.swift */; };\n"),
 ("\t\tSI0001A2 /* CarpeCarbShortcuts.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CarpeCarbShortcuts.swift; sourceTree = \"<group>\"; };\n",
  "\t\tSI0001A2 /* CarpeCarbShortcuts.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CarpeCarbShortcuts.swift; sourceTree = \"<group>\"; };\n\t\tSI0001A3 /* SiriAuth.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SiriAuth.swift; sourceTree = \"<group>\"; };\n"),
 ("\t\t\t\tSI0001A2 /* CarpeCarbShortcuts.swift */,\n",
  "\t\t\t\tSI0001A2 /* CarpeCarbShortcuts.swift */,\n\t\t\t\tSI0001A3 /* SiriAuth.swift */,\n"),
 ("\t\t\t\tSI0001B2 /* CarpeCarbShortcuts.swift in Sources */,\n",
  "\t\t\t\tSI0001B2 /* CarpeCarbShortcuts.swift in Sources */,\n\t\t\t\tSI0001B3 /* SiriAuth.swift in Sources */,\n"),
]
for a, b in edits:
    assert s.count(a) == 1, a[:60]
    s = s.replace(a, b)
open(p, "w").write(s)
EOF
plutil -lint ios/Runner.xcodeproj/project.pbxproj
```

- [ ] **Step 9: Rewrite `CarbIntents.swift`**

Replace `ios/Runner/CarbIntents.swift`:

```swift
import AppIntents
import CarbShared

// MARK: - Log Food Intent

struct LogFoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Food in CarpeCarb"
    static var description = IntentDescription("Look up carbs for a food item and add it to today's total.")

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Food Item", requestValueDialog: "What food would you like to log?")
    var foodItem: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let idToken = try await SiriAuth.idToken()
        let result = try await PerplexityClient.lookupCarbs(for: foodItem, idToken: idToken)

        let now = Date()
        for item in result.items {
            await CarbDataStore.shared.addFood(LoggedFood(item: item, citations: result.citations), now: now)
        }
        let totalToday = CarbDataStore.shared.snapshot(now: now).totalCarbs

        return .result(dialog: IntentDialog(stringLiteral: LogFoodDialog.text(items: result.items, totalToday: totalToday)))
    }
}

// MARK: - Check Carbs Intent

struct CheckCarbsIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Today's Carbs"
    static var description = IntentDescription("Check how many carbs you've eaten today.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let today = CarbDataStore.shared.snapshot()
        let total = today.totalCarbs
        let lastFood = today.lastFoodName
        let lastCarbs = today.lastFoodCarbs
        let goal = today.dailyGoal

        let formattedTotal = String(format: "%.1f", total)

        if total == 0.0 {
            return .result(dialog: "You haven't tracked any carbs today. Open CarpeCarb to start logging.")
        }

        var message = "You've had \(formattedTotal) grams of carbs today."

        if let goal = goal {
            let formattedGoal = String(format: "%.0f", goal)
            if total >= goal {
                let over = String(format: "%.1f", total - goal)
                message += " You're \(over) grams over your \(formattedGoal) gram goal."
            } else {
                let remaining = String(format: "%.1f", goal - total)
                message += " You have \(remaining) grams remaining of your \(formattedGoal) gram goal."
            }
        }

        if !lastFood.isEmpty {
            let formattedLast = String(format: "%.1f", lastCarbs)
            message += " Your last entry was \(lastFood) at \(formattedLast) grams."
        }

        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

// MARK: - Open App Intent

struct OpenCarpeCarbIntent: AppIntent {
    static var title: LocalizedStringResource = "Open CarpeCarb"
    static var description = IntentDescription("Open the CarpeCarb app.")

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
```

- [ ] **Step 10: Build the app**

Run the iOS build check from Global Constraints.
Expected: `** BUILD SUCCEEDED **`, no warnings from `ios/Runner/*.swift` or `ios/CarbShared/**/*.swift`.

- [ ] **Step 11: Commit**

```bash
git add ios/CarbShared/Sources/CarbShared/CarbDataStore.swift ios/CarbShared/Sources/CarbShared/PerplexityClient.swift ios/CarbShared/Sources/CarbShared/LogFoodDialog.swift ios/CarbShared/Tests/CarbSharedTests/CarbDataStoreTests.swift ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift ios/CarbShared/Tests/CarbSharedTests/LogFoodDialogTests.swift ios/Runner/SiriAuth.swift ios/Runner/CarbIntents.swift ios/Runner.xcodeproj/project.pbxproj
git commit -m "fix(siri): fresh Firebase token, every item logged, day-aware totals"
```

---

### Task 3: The widget knows the day

**Files:**
- Modify: `ios/CarbWiseWidget/CarbWiseWidget.swift`, `ios/Runner.xcodeproj/project.pbxproj` (link CarbShared into the widget)
- Delete: `ios/CarbShared.swift`, `ios/CarbWiseWidget/CarbShared.swift` (dead copies of an old CarbShared, in no target; once the widget links the real package they're a trap for edits)

**Interfaces:**
- Consumes: `CarbDataStore.shared.snapshot(now:)`, `CarbDataStore.shared.resetHour`, `CarbDay.nextBoundary` (Tasks 1–2).

- [ ] **Step 1: Link `CarbShared` into the widget target**

From the repo root:

```bash
python3 - <<'EOF'
p = "ios/Runner.xcodeproj/project.pbxproj"; s = open(p).read()
edits = [
 # Build file for the CarbShared product in the widget's Frameworks phase
 ("\t\t250470652F4FC03600AAEB6C /* CarbShared in Frameworks */ = {isa = PBXBuildFile; productRef = 250470642F4FC03600AAEB6C /* CarbShared */; };\n",
  "\t\t250470652F4FC03600AAEB6C /* CarbShared in Frameworks */ = {isa = PBXBuildFile; productRef = 250470642F4FC03600AAEB6C /* CarbShared */; };\n\t\tCW0001P3 /* CarbShared in Frameworks */ = {isa = PBXBuildFile; productRef = CW0001P2 /* CarbShared */; };\n"),
 ("\t\tCW0001E1 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);",
  "\t\tCW0001E1 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\tCW0001P3 /* CarbShared in Frameworks */,\n\t\t\t);"),
 # Target-level package product dependency
 ("\t\t\tname = CarbWiseWidgetExtension;\n\t\t\tproductName = CarbWiseWidgetExtension;\n",
  "\t\t\tname = CarbWiseWidgetExtension;\n\t\t\tpackageProductDependencies = (\n\t\t\t\tCW0001P2 /* CarbShared */,\n\t\t\t);\n\t\t\tproductName = CarbWiseWidgetExtension;\n"),
 ("\t\t250470642F4FC03600AAEB6C /* CarbShared */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = CarbShared;\n\t\t};\n",
  "\t\t250470642F4FC03600AAEB6C /* CarbShared */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = CarbShared;\n\t\t};\n\t\tCW0001P2 /* CarbShared */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = CarbShared;\n\t\t};\n"),
]
for a, b in edits:
    assert s.count(a) == 1, a[:70]
    s = s.replace(a, b)
open(p, "w").write(s)
EOF
plutil -lint ios/Runner.xcodeproj/project.pbxproj
```

- [ ] **Step 2: Make the widget day-aware**

In `ios/CarbWiseWidget/CarbWiseWidget.swift`, apply these replacements.

Imports — replace:

```swift
import WidgetKit
import SwiftUI
import os.log
```

with:

```swift
import CarbShared
import WidgetKit
import SwiftUI
import os.log
```

At the end of `struct CarbWidgetData`, replace:

```swift
    static let empty = CarbWidgetData(
        totalCarbs: 0.0,
        lastFoodName: "",
        lastFoodCarbs: 0.0,
        dailyGoal: nil
    )
}
```

with:

```swift
    static let empty = CarbWidgetData(
        totalCarbs: 0.0,
        lastFoodName: "",
        lastFoodCarbs: 0.0,
        dailyGoal: nil
    )

    /// What to show once the day rolls over: nothing logged yet, goal kept.
    var startingNewDay: CarbWidgetData {
        CarbWidgetData(totalCarbs: 0, lastFoodName: "", lastFoodCarbs: 0, dailyGoal: dailyGoal)
    }
}
```

In `getTimeline`, replace:

```swift
        let currentDate = Date()
        let data = loadData()
        logWidgetData(data, context: "timeline")
        
        let entry = CarbWiseEntry(date: currentDate, data: data)
        
        // Refresh every 15 minutes
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate) ?? currentDate.addingTimeInterval(900)
        logger.debug("Next refresh scheduled for: \(refreshDate.formatted())")
        
        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
```

with:

```swift
        let currentDate = Date()
        let data = loadData(now: currentDate)
        logWidgetData(data, context: "timeline")

        // A second entry at the day boundary (midnight or the user's reset
        // hour) shows 0 even if the app isn't opened before then.
        let dayBoundary = CarbDay.nextBoundary(after: currentDate, resetHour: CarbDataStore.shared.resetHour)
        let entries = [
            CarbWiseEntry(date: currentDate, data: data),
            CarbWiseEntry(date: dayBoundary, data: data.startingNewDay),
        ]

        // Refresh every 15 minutes
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate) ?? currentDate.addingTimeInterval(900)
        logger.debug("Next refresh scheduled for: \(refreshDate.formatted()); day boundary at \(dayBoundary.formatted())")

        let timeline = Timeline(entries: entries, policy: .after(refreshDate))
```

Replace the signature `    private func loadData() -> CarbWidgetData {` with:

```swift
    private func loadData(now: Date = Date()) -> CarbWidgetData {
```

and, inside `loadData`, replace everything from `        guard let defaults = AppGroupConfig.sharedDefaults else {` through the final `return CarbWidgetData(...)` statement:

```swift
        guard let defaults = AppGroupConfig.sharedDefaults else {
            logger.error("❌ Failed to access App Group UserDefaults")
            return .empty
        }
        
        // Use centralized keys for consistency
        let totalCarbs = defaults.double(forKey: AppGroupConfig.Keys.totalCarbs)
        let lastFoodName = defaults.string(forKey: AppGroupConfig.Keys.lastFoodName) ?? ""
        let lastFoodCarbs = defaults.double(forKey: AppGroupConfig.Keys.lastFoodCarbs)
        let goalValue = defaults.double(forKey: AppGroupConfig.Keys.dailyCarbGoal)
        
        logger.debug("   App Group ID: '\(AppGroupConfig.identifier)'")
        logger.debug("   Total carbs: \(totalCarbs)g")
        logger.debug("   Last food: '\(lastFoodName.isEmpty ? "(none)" : lastFoodName)' (\(lastFoodCarbs)g)")
        logger.debug("   Daily goal: \(goalValue > 0 ? "\(goalValue)g" : "(not set)")")
        
        return CarbWidgetData(
            totalCarbs: totalCarbs,
            lastFoodName: lastFoodName,
            lastFoodCarbs: lastFoodCarbs,
            dailyGoal: goalValue > 0 ? goalValue : nil
        )
```

with:

```swift
        // Day-aware: totals stored on an earlier day read as 0.
        let today = CarbDataStore.shared.snapshot(now: now)

        logger.debug("   App Group ID: '\(AppGroupConfig.identifier)'")
        logger.debug("   Total carbs: \(today.totalCarbs)g")
        logger.debug("   Last food: '\(today.lastFoodName.isEmpty ? "(none)" : today.lastFoodName)' (\(today.lastFoodCarbs)g)")
        logger.debug("   Daily goal: \(today.dailyGoal.map { "\($0)g" } ?? "(not set)")")

        return CarbWidgetData(
            totalCarbs: today.totalCarbs,
            lastFoodName: today.lastFoodName,
            lastFoodCarbs: today.lastFoodCarbs,
            dailyGoal: today.dailyGoal
        )
```

(The `AppGroupConfig.isValid` guard before it stays.)

- [ ] **Step 3: Delete the dead duplicates**

```bash
git rm ios/CarbShared.swift ios/CarbWiseWidget/CarbShared.swift
```

- [ ] **Step 4: Build**

Run the iOS build check from Global Constraints.
Expected: `** BUILD SUCCEEDED **`; `CarbWiseWidgetExtension.appex` is built and no warnings come from `ios/CarbWiseWidget/*.swift`.

- [ ] **Step 5: Commit**

```bash
git add ios/CarbWiseWidget/CarbWiseWidget.swift ios/Runner.xcodeproj/project.pbxproj
git commit -m "fix(widget): show today's totals and reset at the day boundary"
```

---

### Task 4: The app writes the day and imports Siri items by day

**Files:**
- Create: `lib/services/siri_import.dart`
- Test: `test/siri_import_test.dart`
- Modify: `lib/config/storage_keys.dart`, `lib/main.dart` (imports, `_updateWidget`, new-day branch of `_loadSavedData`, `_importSiriLoggedItems`)

**Interfaces:**
- Consumes: `dayKey` (Task 1). Siri buffer entries written by `CarbDataStore.addFood` (Task 2): `name`, `carbs`, `loggedAt` (UTC ISO-8601), optional `protein`, `fat`, `fiber`, `calories`, `details`, `citations`.
- Produces: `SiriImport.parse(String json, DateTime now, int resetHour) -> ({List<FoodItem> today, List<FoodItem> earlier})`; `StorageKeys.widgetDayKey = 'dayKey'`, `StorageKeys.widgetResetHour = 'dailyResetHour'`.

- [ ] **Step 1: Write the failing test**

Create `test/siri_import_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/services/siri_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 18, 12, 0);
  String utc(DateTime local) => local.toUtc().toIso8601String();

  test('splits items logged today from items logged on an earlier day', () {
    final json = jsonEncode([
      {'name': 'Oatmeal', 'carbs': 27, 'loggedAt': utc(DateTime(2026, 9, 18, 8, 0))},
      {'name': 'Late snack', 'carbs': 15, 'loggedAt': utc(DateTime(2026, 9, 17, 22, 0))},
    ]);

    final result = SiriImport.parse(json, now, 0);

    expect(result.today.map((i) => i.name), ['Oatmeal']);
    expect(result.earlier.map((i) => i.name), ['Late snack']);
    expect(result.earlier.single.loggedAt, DateTime(2026, 9, 17, 22, 0));
  });

  test('the reset hour decides which day an item belongs to', () {
    // 02:00 on the 18th is still the 17th with a 4 AM reset...
    final json = jsonEncode([
      {'name': 'Night snack', 'carbs': 10, 'loggedAt': utc(DateTime(2026, 9, 18, 2, 0))},
    ]);

    // ...so at 03:00 it's today, at noon it's earlier.
    expect(SiriImport.parse(json, DateTime(2026, 9, 18, 3, 0), 4).today, hasLength(1));
    expect(SiriImport.parse(json, now, 4).earlier, hasLength(1));
  });

  test('keeps macros, details, and citations', () {
    final json = jsonEncode([
      {
        'name': 'Big Mac',
        'carbs': 45,
        'protein': 25,
        'fat': 30.5,
        'fiber': 3,
        'calories': 590,
        'details': "McDonald's [1]",
        'citations': ['https://example.com', 7],
        'loggedAt': utc(DateTime(2026, 9, 18, 11, 0)),
      },
    ]);

    final item = SiriImport.parse(json, now, 0).today.single;

    expect(item.carbs, 45.0);
    expect(item.protein, 25.0);
    expect(item.fat, 30.5);
    expect(item.fiber, 3.0);
    expect(item.calories, 590.0);
    expect(item.details, "McDonald's [1]");
    expect(item.citations, ['https://example.com']);
  });

  test('missing, bad, or future timestamps count as today', () {
    final json = jsonEncode([
      {'name': 'No time', 'carbs': 5},
      {'name': 'Bad time', 'carbs': 5, 'loggedAt': 'yesterday-ish'},
      {'name': 'Future', 'carbs': 5, 'loggedAt': utc(DateTime(2026, 9, 19, 9, 0))},
    ]);

    final result = SiriImport.parse(json, now, 0);

    expect(result.today.map((i) => i.name), ['No time', 'Bad time', 'Future']);
    expect(result.today.first.loggedAt, now);
    expect(result.earlier, isEmpty);
  });

  test('skips entries without a name and rejects a non-list buffer', () {
    final json = jsonEncode([
      {'carbs': 5},
      'junk',
      {'name': 'Apple', 'carbs': 25},
    ]);

    expect(SiriImport.parse(json, now, 0).today.map((i) => i.name), ['Apple']);
    expect(() => SiriImport.parse('{"name": "Apple"}', now, 0), throwsFormatException);
  });
}
```

Run: `flutter test test/siri_import_test.dart`
Expected: FAIL to compile, `services/siri_import.dart` doesn't exist.

- [ ] **Step 2: Implement `SiriImport`**

Create `lib/services/siri_import.dart`:

```dart
import 'dart:convert';

import '../models/food_item.dart';
import '../utils/day_key.dart';

/// Parses the `siriLoggedItems` buffer that Siri writes to the App Group
/// (`CarbDataStore.addFood` in ios/CarbShared) and splits it by day.
class SiriImport {
  SiriImport._();

  /// [today] items join today's list; [earlier] items were logged on a
  /// previous day (the app wasn't opened since) and only go to Apple Health.
  /// Items with a missing, unparseable, or future `loggedAt` count as today.
  /// Entries without a string `name` are skipped.
  ///
  /// Throws [FormatException] if [json] isn't a JSON list.
  static ({List<FoodItem> today, List<FoodItem> earlier}) parse(
      String json, DateTime now, int resetHour) {
    final decoded = jsonDecode(json);
    if (decoded is! List) {
      throw const FormatException('siriLoggedItems is not a JSON list');
    }

    final todayKey = dayKey(now, resetHour);
    final today = <FoodItem>[];
    final earlier = <FoodItem>[];

    for (final raw in decoded.whereType<Map>()) {
      final name = raw['name'];
      if (name is! String) continue;

      final loggedAtRaw = raw['loggedAt'];
      // Siri writes UTC ISO-8601; day keys are in local time.
      final loggedAt =
          loggedAtRaw is String ? DateTime.tryParse(loggedAtRaw)?.toLocal() : null;
      final details = raw['details'];
      final citations = raw['citations'];

      final item = FoodItem(
        name: name,
        carbs: _number(raw['carbs']) ?? 0.0,
        protein: _number(raw['protein']),
        fat: _number(raw['fat']),
        fiber: _number(raw['fiber']),
        calories: _number(raw['calories']),
        details: details is String ? details : null,
        citations:
            citations is List ? citations.whereType<String>().toList() : const [],
        loggedAt: loggedAt ?? now,
      );

      final isEarlier =
          loggedAt != null && dayKey(loggedAt, resetHour).compareTo(todayKey) < 0;
      (isEarlier ? earlier : today).add(item);
    }
    return (today: today, earlier: earlier);
  }

  static double? _number(Object? value) => value is num ? value.toDouble() : null;
}
```

Run: `flutter test test/siri_import_test.dart`
Expected: `+5: All tests passed!`

- [ ] **Step 3: Add the storage keys**

In `lib/config/storage_keys.dart`, replace:

```dart
  static const String widgetFlutterTotalCarbs = 'flutter.total_carbs';
```

with:

```dart
  static const String widgetFlutterTotalCarbs = 'flutter.total_carbs';
  // The day the widget totals belong to (lib/utils/day_key.dart) and the
  // user's reset hour, so Siri and the widget can tell a new day has started.
  static const String widgetDayKey = 'dayKey';
  static const String widgetResetHour = 'dailyResetHour';
```

- [ ] **Step 4: Write the day to the App Group**

In `lib/main.dart`, add after `import 'services/cloud_sync_service.dart';`:

```dart
import 'services/siri_import.dart';
```

Replace the end of `_updateWidget()`:

```dart
    await HomeWidget.saveWidgetData<double>(
        StorageKeys.widgetDailyCarbGoal, dailyCarbGoal ?? 0.0);
    await HomeWidget.updateWidget(iOSName: StorageKeys.widgetName);
  }
```

with:

```dart
    await HomeWidget.saveWidgetData<double>(
        StorageKeys.widgetDailyCarbGoal, dailyCarbGoal ?? 0.0);
    await _saveWidgetDay();
    await HomeWidget.updateWidget(iOSName: StorageKeys.widgetName);
  }

  /// Tells Siri and the widget which day the stored totals belong to.
  Future<void> _saveWidgetDay() async {
    await HomeWidget.saveWidgetData<String>(
        StorageKeys.widgetDayKey, _todayString());
    await HomeWidget.saveWidgetData<int>(StorageKeys.widgetResetHour, resetHour);
  }
```

In the new-day branch of `_loadSavedData()`, replace:

```dart
      await HomeWidget.saveWidgetData<double>(
          StorageKeys.widgetLastFoodCarbs, 0.0);
      await HomeWidget.updateWidget(iOSName: StorageKeys.widgetName);
      if (!mounted || token != _loadSavedDataToken) return;
      setState(() {
        foodItems = [];
        dailyCarbGoal = savedGoal;
      });
      return;
    }
```

with:

```dart
      await HomeWidget.saveWidgetData<double>(
          StorageKeys.widgetLastFoodCarbs, 0.0);
      await _saveWidgetDay();
      await HomeWidget.updateWidget(iOSName: StorageKeys.widgetName);
      if (!mounted || token != _loadSavedDataToken) return;
      setState(() {
        foodItems = [];
        dailyCarbGoal = savedGoal;
      });
      // Siri may have logged food this morning before the app was opened.
      await _importSiriLoggedItems();
      return;
    }
```

(Before this change the new-day branch returned without importing, so this morning's Siri items waited until the next resume.)

- [ ] **Step 5: Import Siri items by day**

Replace the whole `_importSiriLoggedItems()` method (from `  Future<void> _importSiriLoggedItems() async {` up to, not including, `  Future<void> _saveData() async {`) with:

```dart
  Future<void> _importSiriLoggedItems() async {
    final token = ++_importSiriItemsToken;
    final siriItemsJson = await HomeWidget.getWidgetData<String>(
        StorageKeys.widgetSiriLoggedItems);
    if (!mounted || token != _importSiriItemsToken) return;
    if (siriItemsJson == null) return;

    try {
      final siri =
          SiriImport.parse(siriItemsJson, DateTime.now(), resetHour);
      if (siri.today.isEmpty && siri.earlier.isEmpty) return;

      // Insert one at a time to keep AnimatedList's internal count in sync
      // with the data list.
      for (final foodItem in siri.today) {
        if (!mounted || token != _importSiriItemsToken) return;
        setState(() {
          foodItems.insert(0, foodItem);
        });
        _listKey.currentState
            ?.insertItem(0, duration: const Duration(milliseconds: 400));
      }

      // Clear the Siri buffer so we don't re-import on next launch
      await HomeWidget.saveWidgetData<String?>(
          StorageKeys.widgetSiriLoggedItems, null);
      await _saveData();
      await _updateWidget();

      // Items from an earlier day stay out of today's list but still go to
      // Apple Health at the time they were logged.
      if (_premiumService.isHealthSyncEnabled) {
        for (final foodItem in [...siri.today, ...siri.earlier]) {
          _writeToHealthKit(foodItem);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to import Siri logged items: $e');
    }
  }
```

- [ ] **Step 6: Run the Dart checks**

Run: `flutter analyze && flutter test`
Expected: `No issues found!`, then `All tests passed!` (77 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/services/siri_import.dart test/siri_import_test.dart lib/config/storage_keys.dart lib/main.dart
git commit -m "fix: write the day for Siri and the widget; import Siri items by day"
```

---

### Task 5: Stop copying the Firebase token

**Files:**
- Modify: `lib/main.dart`, `lib/services/perplexity_firebase_service.dart`, `lib/config/storage_keys.dart`, `ios/Runner/AppDelegate.swift`, `ios/Runner.xcodeproj/project.pbxproj`
- Delete: `ios/Runner/TokenStorageChannel.swift`

**Interfaces:**
- Consumes: `CarbDataStore.appGroupID`, `KeychainHelper.delete(forKey:)` (existing).
- Removes: `StorageKeys.firebaseIdToken`, `StorageKeys.tokenStorageChannel`, `_refreshSharedFirebaseToken`, `TokenStorageChannel`.

- [ ] **Step 1: Remove the Dart token copies**

In `lib/main.dart`, replace:

```dart
  // Initialize HomeWidget for iOS widget data sharing
  HomeWidget.setAppGroupId(StorageKeys.appGroupId);

  // Persist the Firebase ID token to the shared App Group UserDefaults so
  // Siri App Intents (and Watch extensions) can authenticate Cloud Function calls.
  _refreshSharedFirebaseToken();

  runApp(const CarbTrackerApp());
}

/// Fetches a fresh Firebase ID token and writes it to the shared App Group
/// UserDefaults so Siri App Intents and Watch extensions can auth Cloud Function calls.
Future<void> _refreshSharedFirebaseToken() async {
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) return;
    await HomeWidget.saveWidgetData<String>(StorageKeys.firebaseIdToken, token);
  } catch (e) {
    if (kDebugMode) debugPrint('Failed to refresh shared Firebase token: $e');
  }
}
```

with:

```dart
  // Initialize HomeWidget for iOS widget data sharing
  HomeWidget.setAppGroupId(StorageKeys.appGroupId);

  runApp(const CarbTrackerApp());
}
```

In `lib/services/perplexity_firebase_service.dart`, delete these lines:

```dart
import 'package:flutter/services.dart';
import '../config/storage_keys.dart';
```

```dart
  static const _tokenChannel = MethodChannel(StorageKeys.tokenStorageChannel);
```

```dart
    // Keep the shared token fresh so Siri/Watch extensions can auth.
    // Stored in Keychain (secure) + App Group UserDefaults (backward compat).
    try {
      await _tokenChannel.invokeMethod<void>('saveToken', idToken);
    } catch (_) {
      // Non-fatal — token sharing is best-effort.
    }

```

In `lib/config/storage_keys.dart`, delete:

```dart
  // Firebase ID token — written to Keychain + App Group UserDefaults for Siri/Watch auth
  static const String firebaseIdToken = 'firebaseIdToken';

  // MethodChannel for secure token storage (TokenStorageChannel.swift)
  static const String tokenStorageChannel = 'com.carpecarb/tokenstorage';

```

- [ ] **Step 2: Remove `TokenStorageChannel` and clean up the old copies**

In `ios/Runner/AppDelegate.swift`, delete the line:

```swift
  private var tokenStorageChannel: TokenStorageChannel?
```

Replace:

```swift
    logger.info("🚀 Application launching")
```

with:

```swift
    logger.info("🚀 Application launching")

    // Siri now gets its own fresh Firebase token (SiriAuth.swift). Remove the
    // copy older builds kept in App Group UserDefaults (plain text) and the
    // Keychain so it doesn't linger on updated devices.
    UserDefaults(suiteName: CarbDataStore.appGroupID)?.removeObject(forKey: "firebaseIdToken")
    KeychainHelper.delete(forKey: "firebaseIdToken")
```

Replace:

```swift
    cloudSyncChannel = CloudSyncChannel(messenger: registrar.messenger())
    logger.info("✓ CloudSyncChannel registered successfully")

    guard let tokenRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "TokenStorageChannel") else {
      logger.error("❌ Failed to get plugin registrar for TokenStorageChannel")
      return
    }
    tokenStorageChannel = TokenStorageChannel(messenger: tokenRegistrar.messenger())
    logger.info("✓ TokenStorageChannel registered successfully")
  }
```

with:

```swift
    cloudSyncChannel = CloudSyncChannel(messenger: registrar.messenger())
    logger.info("✓ CloudSyncChannel registered successfully")
  }
```

Delete the file and its project references, from the repo root:

```bash
git rm ios/Runner/TokenStorageChannel.swift
python3 - <<'EOF'
p = "ios/Runner.xcodeproj/project.pbxproj"; s = open(p).read()
for a in [
 "\t\t1C2429AFA1FF4832BD317300 /* TokenStorageChannel.swift in Sources */ = {isa = PBXBuildFile; fileRef = E8893DCA54D941609C542800 /* TokenStorageChannel.swift */; };\n",
 "\t\tE8893DCA54D941609C542800 /* TokenStorageChannel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Runner/TokenStorageChannel.swift; sourceTree = \"<group>\"; };\n",
 "\t\t\t\tE8893DCA54D941609C542800 /* TokenStorageChannel.swift */,\n",
 "\t\t\t\t1C2429AFA1FF4832BD317300 /* TokenStorageChannel.swift in Sources */,\n",
]:
    assert s.count(a) == 1, a[:70]
    s = s.replace(a, "")
open(p, "w").write(s)
EOF
plutil -lint ios/Runner.xcodeproj/project.pbxproj
```

- [ ] **Step 3: Confirm nothing else refers to the token copy**

Run: `grep -rn "firebaseIdToken\|tokenStorageChannel\|TokenStorageChannel\|_refreshSharedFirebaseToken" lib test integration_test ios/Runner ios/CarbShared/Sources ios/CarbWiseWidget ios/Runner.xcodeproj/project.pbxproj`
Expected: only the two cleanup lines in `ios/Runner/AppDelegate.swift`.

- [ ] **Step 4: Run every check**

```bash
flutter analyze && flutter test
(cd ios/CarbShared && swift test)
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/siri-check CODE_SIGNING_ALLOWED=NO clean build
for p in build/siri-check/Build/Products/Release-iphoneos/Runner.app/Info.plist build/siri-check/Build/Products/Release-iphoneos/Runner.app/PlugIns/CarbWiseWidgetExtension.appex/Info.plist; do /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$p"; done
```

Expected: `No issues found!`; `All tests passed!` (77); `✔ Test run with 22 tests in 5 suites passed`; `** BUILD SUCCEEDED **`; app and widget print the same version and build (currently 1.0.2 / 4). `build/` is git-ignored.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart lib/services/perplexity_firebase_service.dart lib/config/storage_keys.dart ios/Runner/AppDelegate.swift ios/Runner.xcodeproj/project.pbxproj
git commit -m "fix: stop copying the Firebase token for Siri; remove old copies"
```

---

### Task 6: Verify on a device (needs James)

No code. On an iPhone with a build from this branch:

- [ ] Leave the app closed for more than an hour, then "Log food in CarpeCarb" → it logs and speaks a total (no "Server error (401)").
- [ ] Siri after more than an hour, twice: once with the app swiped away (exercises `SiriAuth`'s `FirebaseApp.configure()` path), once with it only backgrounded. Both log and speak a total.
- [ ] "Log food in CarpeCarb", "burger and fries" → two items logged; the reply lists both.
- [ ] Next morning, before opening the app: "How many carbs today in CarpeCarb" says nothing has been tracked yet; the widget shows 0 after midnight (or the reset hour).
- [ ] Leave the app suspended (not force-quit) overnight, open it in the morning → the list is empty or today-only, and the widget and Siri don't include yesterday.
- [ ] Log something with Siri late at night, open the app the next day → it's in Apple Health at its real time but not in today's list.
- [ ] Siri-logged items show macros (protein/fat/fiber/calories) in the app's detail view and Apple Health.
- [ ] On a device that has never had CarpeCarb installed (Firebase's saved user survives deleting the app, so a reinstall still has a user), "Log food in CarpeCarb" → "Open CarpeCarb once to finish setting up Siri."
- [ ] Set Region to Thailand (or Calendar to Buddhist) → the widget and Siri totals match the app.
