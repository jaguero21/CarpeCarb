# iCloud Sync Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make two devices agree: remote changes arrive while the app is open, a delete on one device stays deleted on the other, and a push that iCloud didn't take is reported as failed instead of shown as synced.

**Architecture:** All merge decisions move into one pure Dart module (`lib/services/sync_merge.dart`) that takes this device's state and the cloud's and returns the merged state — no I/O, so the rules are tested directly. Deletes are carried as markers (deleted item ids for today; per-favourite `{updatedAt, deleted}` records) and settings carry the time they were last changed, so "newest wins" can be decided instead of guessed. A thin store (`sync_store.dart`) reads and writes that state in SharedPreferences and records local changes; a codec (`sync_payload.dart`) converts it to and from the flat iCloud payload. On the native side `CloudSyncStore` compares the pulled timestamp against the one captured *before* the pull (the bug that stopped live sync), carries the three new keys, and reports whether a push actually landed.

**Tech Stack:** Flutter 3.41 / Dart 3.11, `flutter_test`, `shared_preferences`; Swift 6.4 toolchain (package in Swift 5 mode), Swift Testing, NSUbiquitousKeyValueStore, App Intents, `home_widget`.

**Spec:** `docs/superpowers/specs/2026-09-20-icloud-sync-design.md`

## Global Constraints

- Commits carry NO `Co-Authored-By` or other attribution trailer. Explicit `git add` paths only. Never stage `.superpowers/`, `build/`, or untracked files you didn't create for the task.
- Branch: `feature/icloud-sync` (the spec is already committed there).
- **Merge rules** (Task 1 implements them; later tasks must not re-decide them):
  - Today's items merge **only** when the cloud payload's `last_save_date` equals this device's day key. A payload from another day is ignored for items and deleted ids entirely; local data is left alone.
  - Merged items = union of both sides minus the union of both sides' deleted ids, newest `loggedAt` first, ties broken by `id`.
  - Favourites are keyed by the lower-cased name (the app's existing dedupe key). Per name the newer change wins; on an equal timestamp the delete wins. A favourite with no change record (written by an older build) counts as added at epoch 0.
  - Delete markers for favourites older than 60 days are pruned on merge.
  - Settings (the five goals plus the reset hour) move as one value: the side with the newer `settings_updated_at` wins. A local `updatedAt` of null means "never changed here", so the cloud's win however old.
  - The merged state is emitted deterministically (favourites in sorted-key order, deleted ids sorted), and a second merge of the same inputs changes nothing — that is what stops the two devices pushing at each other forever.
- **New keys, spelled exactly:** `food_items_deleted`, `saved_foods_changes`, `settings_updated_at`. They are SharedPreferences keys, iCloud payload keys, and entries in `CloudSyncStore.dataKeys` — a pull drops any key not listed there.
- **Siri buffer channel:** name `com.carpecarb/siribuffer`, method `takeLoggedItems`, returns the buffer JSON or nil and empties it in the same main-actor step.
- No force unwraps / `try!` / `fatalError` / silently swallowed errors in shipped code. A failed push shows the existing failed icon and leaves `cloud_last_modified` alone so the next change retries.
- The Watch app targets are out of scope; don't edit them.
- `project.pbxproj` edits use the exact script given in Task 4 (it asserts each anchor appears exactly once and ends with `plutil -lint`).
- Checks: `flutter analyze && flutter test` from the repo root; `cd ios/CarbShared && swift test`; iOS build from the repo root:
  `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. Third-party output that is not yours to fix: an `in_app_purchase_storekit` header deprecation warning and two `libtool: warning: '…' has no symbols` lines.
- Do not run `dart format` over a whole existing file. The repo's files are not uniformly formatted, and reformatting one buries the change in noise. Format only new files.

## How to apply the edits in this plan

Every code block in this plan is the exact text that was built and tested. Copy it byte-for-byte — retyping loses characters (curly quotes, `\u` escapes, trailing spaces).

- **New file:** `python3 .superpowers/sdd/extract_block.py TASK_BRIEF --list` to find the block, then `extract_block.py TASK_BRIEF N path/to/file` writes it.
- **Edit to an existing file:** each edit is a "replace / with" pair of consecutive blocks. Extract both and apply them with the helper, which fails unless the old text appears exactly once:

```bash
python3 .superpowers/sdd/extract_block.py TASK_BRIEF N /tmp/old.txt
python3 .superpowers/sdd/extract_block.py TASK_BRIEF N+1 /tmp/new.txt
python3 .superpowers/sdd/replace_block.py lib/main.dart /tmp/old.txt /tmp/new.txt
```

If `replace_block.py` reports 0 or 2+ occurrences, stop and report NEEDS_CONTEXT — don't hand-edit around it.

## File Map

| File | Status | Responsibility |
|---|---|---|
| `lib/services/sync_merge.dart` | create | the merge rules and the state they work on; no I/O |
| `lib/services/sync_payload.dart` | create | `SyncState` ↔ the flat iCloud payload, including old payloads |
| `lib/services/sync_store.dart` | create | read/write the synced state in SharedPreferences; record local changes |
| `lib/config/storage_keys.dart` | modify | the three new keys |
| `test/sync_merge_test.dart`, `test/sync_payload_test.dart`, `test/sync_store_test.dart` | create | Dart tests |
| `ios/CarbShared/Sources/CarbShared/CloudSyncStore.swift` | modify | carry the new keys, report push failures, notify on real remote changes |
| `ios/Runner/CloudSyncChannel.swift` | modify | return the store's push result |
| `ios/CarbShared/Tests/CarbSharedTests/CloudSyncStoreTests.swift` | create | Swift tests against an in-memory key-value store |
| `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift` | modify | `takeSiriLoggedItems()` |
| `ios/Runner/SiriBufferChannel.swift` | create | hand the buffer to Flutter and clear it in one step |
| `ios/Runner/AppDelegate.swift`, `ios/Runner.xcodeproj/project.pbxproj` | modify | register the new channel |
| `lib/services/cloud_sync_service.dart` | modify | return what the native push reported |
| `lib/services/siri_buffer_service.dart` | create | Dart side of the buffer channel |
| `lib/main.dart` | modify | merge on pull, push only what changed, record deletes, rebuild the list |
| `lib/screens/settings_page.dart` | modify | record favourite deletes |
| `test/widget_test.dart` | modify | remote-change tests; Siri buffer stub |
| `docs/superpowers/plans/2026-09-20-icloud-sync.md` | modify | device checklist (Task 7) |

---

### Task 1: Merge rules

The pure module every later task depends on. No SharedPreferences, no channels — it takes two states and returns one.

**Files:**
- Create: `lib/services/sync_merge.dart`
- Test: `test/sync_merge_test.dart`

**Interfaces:**
- Consumes: `FoodItem` from `lib/models/food_item.dart` (has `id`, `name`, `carbs`, `loggedAt`, `toJson()`, `FoodItem.fromJson`).
- Produces: `favoriteKey(String) → String`; `FavoriteChange({required DateTime updatedAt, required bool deleted})` with `FavoriteChange.legacyAdd`, `beats(other)`, `toJson()`, `FavoriteChange.fromJson(Object?)`; `SyncSettings` (the five nullable goals, `int resetHour`, `DateTime? updatedAt`, `copyWith({DateTime? updatedAt})`); `SyncState({required String dayKey, required List<FoodItem> items, required Set<String> deletedItemIds, required List<FoodItem> favorites, required Map<String, FavoriteChange> favoriteChanges, required SyncSettings settings})` with `copyWith`; `mergeSyncState({required SyncState local, required SyncState cloud, required DateTime now, Duration tombstoneTtl})`; `canonicalSyncJson(SyncState)`; `syncStateDiffers(SyncState a, SyncState b)`.

- [ ] **Step 1: Write the failing test**

Create `test/sync_merge_test.dart`:

```dart
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/sync_merge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 20, 12, 0);
  const today = '2026-09-20';

  FoodItem item(String id, String name, {double carbs = 10, DateTime? at}) =>
      FoodItem(id: id, name: name, carbs: carbs, loggedAt: at ?? DateTime(2026, 9, 20, 8));

  FavoriteChange change(DateTime at, {bool deleted = false}) =>
      FavoriteChange(updatedAt: at, deleted: deleted);

  SyncState state({
    String dayKey = today,
    List<FoodItem> items = const [],
    Set<String> deleted = const {},
    List<FoodItem> favorites = const [],
    Map<String, FavoriteChange> changes = const {},
    SyncSettings settings = const SyncSettings(),
  }) =>
      SyncState(
        dayKey: dayKey,
        items: items,
        deletedItemIds: deleted,
        favorites: favorites,
        favoriteChanges: changes,
        settings: settings,
      );

  SyncState merge(SyncState local, SyncState cloud) =>
      mergeSyncState(local: local, cloud: cloud, now: now);

  group('today\'s food items', () {
    test('items added on two devices while apart both survive', () {
      final merged = merge(
        state(items: [item('a', 'Apple')]),
        state(items: [item('b', 'Bagel', at: DateTime(2026, 9, 20, 9))]),
      );

      expect(merged.items.map((i) => i.name), ['Bagel', 'Apple']); // newest first
    });

    test('an item deleted on this device does not come back from the cloud', () {
      final merged = merge(
        state(items: [item('a', 'Apple')], deleted: {'b'}),
        state(items: [item('a', 'Apple'), item('b', 'Bagel')]),
      );

      expect(merged.items.map((i) => i.id), ['a']);
      expect(merged.deletedItemIds, {'b'});
    });

    test('a delete from the cloud removes the item here', () {
      final merged = merge(
        state(items: [item('a', 'Apple'), item('b', 'Bagel')]),
        state(items: [item('a', 'Apple')], deleted: {'b'}),
      );

      expect(merged.items.map((i) => i.id), ['a']);
    });

    test('a delete stays deleted when the other device pushes the item again', () {
      final first = merge(
        state(items: [item('a', 'Apple')], deleted: {'b'}),
        state(items: [item('a', 'Apple'), item('b', 'Bagel')]),
      );
      final second = merge(first, state(items: [item('b', 'Bagel')]));

      expect(second.items.map((i) => i.id), ['a']);
    });

    test('undo (dropping the marker) lets the item come back', () {
      final merged = merge(
        state(items: [item('a', 'Apple'), item('b', 'Bagel')]),
        state(items: [item('a', 'Apple'), item('b', 'Bagel')]),
      );

      expect(merged.items.map((i) => i.id), ['a', 'b']);
    });

    test('reset-today clears both devices', () {
      final merged = merge(
        state(deleted: {'a', 'b'}),
        state(items: [item('a', 'Apple'), item('b', 'Bagel')]),
      );

      expect(merged.items, isEmpty);
    });

    test('a cloud payload from another day is ignored, items and deletes alike', () {
      final merged = merge(
        state(items: [item('a', 'Apple')]),
        state(dayKey: '2026-09-19', items: [item('y', 'Yesterday')], deleted: {'a'}),
      );

      expect(merged.items.map((i) => i.id), ['a']);
      expect(merged.deletedItemIds, isEmpty);
    });

    test('items logged at the same moment keep a stable order on both devices', () {
      final sameTime = DateTime(2026, 9, 20, 8);
      final ab = merge(state(items: [item('a', 'A', at: sameTime)]),
          state(items: [item('b', 'B', at: sameTime)]));
      final ba = merge(state(items: [item('b', 'B', at: sameTime)]),
          state(items: [item('a', 'A', at: sameTime)]));

      expect(ab.items.map((i) => i.id), ['a', 'b']);
      expect(ba.items.map((i) => i.id), ['a', 'b']);
    });
  });

  group('favourites', () {
    test('a favourite deleted here does not come back from the cloud', () {
      final merged = merge(
        state(changes: {'bagel': change(now, deleted: true)}),
        state(favorites: [item('b', 'Bagel')], changes: {'bagel': change(now.subtract(const Duration(hours: 1)))}),
      );

      expect(merged.favorites, isEmpty);
      expect(merged.favoriteChanges['bagel']!.deleted, isTrue);
    });

    test('re-adding after a delete wins', () {
      final merged = merge(
        state(favorites: [item('b', 'Bagel')], changes: {'bagel': change(now)}),
        state(changes: {'bagel': change(now.subtract(const Duration(minutes: 5)), deleted: true)}),
      );

      expect(merged.favorites.map((f) => f.name), ['Bagel']);
    });

    test('"Reset favourites" propagates', () {
      final merged = merge(
        state(changes: {
          'apple': change(now, deleted: true),
          'bagel': change(now, deleted: true),
        }),
        state(favorites: [item('a', 'Apple'), item('b', 'Bagel')]),
      );

      expect(merged.favorites, isEmpty);
    });

    test('favourites saved by an older build are kept but lose to any change', () {
      final kept = merge(state(favorites: [item('a', 'Apple')]), state());
      expect(kept.favorites.map((f) => f.name), ['Apple']);

      final deleted = merge(
        state(changes: {'apple': change(now, deleted: true)}),
        state(favorites: [item('a', 'Apple')]), // no change record: legacy
      );
      expect(deleted.favorites, isEmpty);
    });

    test('a delete and an add at the same instant resolve to the delete on both devices', () {
      final here = merge(state(changes: {'bagel': change(now, deleted: true)}),
          state(favorites: [item('b', 'Bagel')], changes: {'bagel': change(now)}));
      final there = merge(state(favorites: [item('b', 'Bagel')], changes: {'bagel': change(now)}),
          state(changes: {'bagel': change(now, deleted: true)}));

      expect(here.favorites, isEmpty);
      expect(there.favorites, isEmpty);
    });

    test('delete markers older than 60 days are dropped', () {
      final old = now.subtract(const Duration(days: 61));
      final merged = merge(state(changes: {'bagel': change(old, deleted: true)}), state());

      expect(merged.favoriteChanges, isEmpty);
    });

    test('favourites come back in a stable order on both devices', () {
      final here = merge(state(favorites: [item('b', 'Bagel')]), state(favorites: [item('a', 'Apple')]));
      final there = merge(state(favorites: [item('a', 'Apple')]), state(favorites: [item('b', 'Bagel')]));

      expect(here.favorites.map((f) => f.name), ['Apple', 'Bagel']);
      expect(there.favorites.map((f) => f.name), ['Apple', 'Bagel']);
    });
  });

  group('goals and reset hour', () {
    final localSettings = SyncSettings(dailyCarbGoal: 100, resetHour: 4, updatedAt: now);
    final cloudSettings =
        SyncSettings(dailyCarbGoal: 150, resetHour: 0, updatedAt: now.add(const Duration(minutes: 1)));

    test('the newer change wins', () {
      final merged = merge(state(settings: localSettings), state(settings: cloudSettings));
      expect(merged.settings.dailyCarbGoal, 150);
    });

    test('a stale device does not wipe goals changed here', () {
      final stale = SyncSettings(updatedAt: now.subtract(const Duration(days: 1)));
      final merged = merge(state(settings: localSettings), state(settings: stale));

      expect(merged.settings.dailyCarbGoal, 100);
      expect(merged.settings.resetHour, 4);
    });

    test('a device that has never changed settings adopts the cloud\'s', () {
      final merged = merge(
        state(settings: const SyncSettings()),
        state(settings: SyncSettings(dailyCarbGoal: 150, updatedAt: DateTime.fromMillisecondsSinceEpoch(0))),
      );

      expect(merged.settings.dailyCarbGoal, 150);
    });
  });

  group('convergence', () {
    test('merging again changes nothing, so devices stop pushing', () {
      final local = state(
        items: [item('a', 'Apple')],
        deleted: {'x'},
        favorites: [item('f', 'Bagel')],
        changes: {'bagel': change(now)},
        settings: SyncSettings(dailyCarbGoal: 100, updatedAt: now),
      );
      final cloud = state(items: [item('b', 'Bagel', at: DateTime(2026, 9, 20, 9))]);

      final first = merge(local, cloud);
      final second = merge(first, first);

      expect(syncStateDiffers(second, first), isFalse);
    });

    test('a merge that gained nothing is not worth pushing', () {
      final local = state(items: [item('a', 'Apple')]);
      final cloud = state(items: [item('a', 'Apple')]);

      expect(syncStateDiffers(merge(local, cloud), cloud), isFalse);
    });

    test('a merge that gained an item is worth pushing', () {
      final local = state(items: [item('a', 'Apple')]);
      final cloud = state(items: [item('b', 'Bagel')]);

      expect(syncStateDiffers(merge(local, cloud), cloud), isTrue);
    });
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/sync_merge_test.dart`
Expected: fails to compile — `Target of URI doesn't exist: 'package:carb_tracker/services/sync_merge.dart'`.

- [ ] **Step 3: Write the module**

Create `lib/services/sync_merge.dart`:

```dart
import 'dart:convert';

import '../models/food_item.dart';

/// The key a favourite is tracked under: its name, trimmed and lower-cased
/// (the same rule the app already uses to dedupe favourites).
String favoriteKey(String name) => name.trim().toLowerCase();

/// A favourite's most recent add or delete, so devices can agree on which
/// happened last instead of unioning their lists (which resurrected deletes).
class FavoriteChange {
  const FavoriteChange({required this.updatedAt, required this.deleted});

  final DateTime updatedAt;
  final bool deleted;

  /// Favourites saved before this existed count as added long ago, so any
  /// real change on either device beats them.
  static final FavoriteChange legacyAdd = FavoriteChange(
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0), deleted: false);

  /// True when this change should win over [other]. A delete wins a tie so a
  /// deletion is never lost, and both devices decide the same way.
  bool beats(FavoriteChange other) {
    if (updatedAt.isAfter(other.updatedAt)) return true;
    if (other.updatedAt.isAfter(updatedAt)) return false;
    return deleted && !other.deleted;
  }

  Map<String, dynamic> toJson() =>
      {'updatedAt': updatedAt.millisecondsSinceEpoch, 'deleted': deleted};

  static FavoriteChange? fromJson(Object? json) {
    if (json is! Map) return null;
    final updatedAt = json['updatedAt'];
    if (updatedAt is! int) return null;
    return FavoriteChange(
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt),
      deleted: json['deleted'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FavoriteChange &&
      other.updatedAt == updatedAt &&
      other.deleted == deleted;

  @override
  int get hashCode => Object.hash(updatedAt, deleted);
}

/// Goals and the daily reset hour, with when the user last changed them on
/// this device. [updatedAt] is null when they have never been changed here.
class SyncSettings {
  const SyncSettings({
    this.dailyCarbGoal,
    this.proteinGoal,
    this.fatGoal,
    this.fiberGoal,
    this.caloriesGoal,
    this.resetHour = 0,
    this.updatedAt,
  });

  final double? dailyCarbGoal;
  final double? proteinGoal;
  final double? fatGoal;
  final double? fiberGoal;
  final double? caloriesGoal;
  final int resetHour;
  final DateTime? updatedAt;

  SyncSettings copyWith({DateTime? updatedAt}) => SyncSettings(
        dailyCarbGoal: dailyCarbGoal,
        proteinGoal: proteinGoal,
        fatGoal: fatGoal,
        fiberGoal: fiberGoal,
        caloriesGoal: caloriesGoal,
        resetHour: resetHour,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is SyncSettings &&
      other.dailyCarbGoal == dailyCarbGoal &&
      other.proteinGoal == proteinGoal &&
      other.fatGoal == fatGoal &&
      other.fiberGoal == fiberGoal &&
      other.caloriesGoal == caloriesGoal &&
      other.resetHour == resetHour &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(dailyCarbGoal, proteinGoal, fatGoal,
      fiberGoal, caloriesGoal, resetHour, updatedAt);
}

/// Everything that syncs between devices.
class SyncState {
  const SyncState({
    required this.dayKey,
    this.items = const [],
    this.deletedItemIds = const {},
    this.favorites = const [],
    this.favoriteChanges = const {},
    this.settings = const SyncSettings(),
  });

  /// The day [items] belong to (`last_save_date`).
  final String dayKey;
  final List<FoodItem> items;
  final Set<String> deletedItemIds;
  final List<FoodItem> favorites;

  /// Favourite key → its most recent add or delete.
  final Map<String, FavoriteChange> favoriteChanges;
  final SyncSettings settings;

  SyncState copyWith({
    List<FoodItem>? items,
    Set<String>? deletedItemIds,
    List<FoodItem>? favorites,
    Map<String, FavoriteChange>? favoriteChanges,
    SyncSettings? settings,
  }) =>
      SyncState(
        dayKey: dayKey,
        items: items ?? this.items,
        deletedItemIds: deletedItemIds ?? this.deletedItemIds,
        favorites: favorites ?? this.favorites,
        favoriteChanges: favoriteChanges ?? this.favoriteChanges,
        settings: settings ?? this.settings,
      );
}

/// Merges what this device has with what came from iCloud.
///
/// Food items and favourites merge (so neither device loses an entry made
/// while they were apart) but respect deletions; goals and the reset hour are
/// whole-value, newest-change-wins.
SyncState mergeSyncState({
  required SyncState local,
  required SyncState cloud,
  required DateTime now,
  Duration tombstoneTtl = const Duration(days: 60),
}) {
  // ── Today's food items ──
  // A cloud payload about another day says nothing about today, so it is
  // ignored here: both its items and its deleted ids belong to that day.
  var items = local.items;
  var deletedItemIds = local.deletedItemIds;
  if (cloud.dayKey == local.dayKey) {
    deletedItemIds = {...local.deletedItemIds, ...cloud.deletedItemIds};
    final seen = <String>{};
    final merged = <FoodItem>[];
    for (final item in [...cloud.items, ...local.items]) {
      if (deletedItemIds.contains(item.id)) continue;
      if (seen.add(item.id)) merged.add(item);
    }
    // Newest first, with the id as a tie-break so both devices agree on the
    // order (an order that differed would push back and forth forever).
    merged.sort((a, b) {
      final byTime = b.loggedAt.compareTo(a.loggedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    items = merged;
  }

  // ── Favourites ──
  final localItems = {for (final f in local.favorites) favoriteKey(f.name): f};
  final cloudItems = {for (final f in cloud.favorites) favoriteKey(f.name): f};
  final changes = <String, FavoriteChange>{};
  final favorites = <FoodItem>[];
  final keys = <String>{
    ...local.favoriteChanges.keys,
    ...cloud.favoriteChanges.keys,
    ...localItems.keys,
    ...cloudItems.keys,
  }.toList()
    ..sort();

  for (final key in keys) {
    final localChange = local.favoriteChanges[key] ??
        (localItems.containsKey(key) ? FavoriteChange.legacyAdd : null);
    final cloudChange = cloud.favoriteChanges[key] ??
        (cloudItems.containsKey(key) ? FavoriteChange.legacyAdd : null);
    final FavoriteChange winner;
    if (localChange == null) {
      if (cloudChange == null) continue;
      winner = cloudChange;
    } else if (cloudChange == null) {
      winner = localChange;
    } else {
      winner = cloudChange.beats(localChange) ? cloudChange : localChange;
    }

    if (winner.deleted) {
      // Keep the delete around long enough for a device that has been away to
      // see it, then forget it.
      if (now.difference(winner.updatedAt) < tombstoneTtl) {
        changes[key] = winner;
      }
      continue;
    }
    final item = (winner == cloudChange ? cloudItems[key] : localItems[key]) ??
        localItems[key] ??
        cloudItems[key];
    if (item == null) continue;
    favorites.add(item);
    if (winner.updatedAt.millisecondsSinceEpoch > 0) changes[key] = winner;
  }

  // ── Goals and reset hour: newest change wins ──
  final localAt = local.settings.updatedAt;
  final cloudAt = cloud.settings.updatedAt;
  final takeCloud =
      cloudAt != null && (localAt == null || cloudAt.isAfter(localAt));

  return SyncState(
    dayKey: local.dayKey,
    items: items,
    deletedItemIds: deletedItemIds,
    favorites: favorites,
    favoriteChanges: changes,
    settings: takeCloud ? cloud.settings : local.settings,
  );
}

/// What two states must agree on for a device to stop pushing. Deliberately
/// excludes `cloud_last_modified`, which changes on every push.
String canonicalSyncJson(SyncState state) {
  String itemsJson(List<FoodItem> list) =>
      jsonEncode(list.map((f) => f.toJson()).toList());
  final changeKeys = state.favoriteChanges.keys.toList()..sort();
  return jsonEncode({
    'day': state.dayKey,
    'items': itemsJson(state.items),
    'deleted': state.deletedItemIds.toList()..sort(),
    'favorites': itemsJson(state.favorites),
    'changes': {
      for (final k in changeKeys) k: state.favoriteChanges[k]!.toJson()
    },
    'settings': {
      'carbs': state.settings.dailyCarbGoal,
      'protein': state.settings.proteinGoal,
      'fat': state.settings.fatGoal,
      'fiber': state.settings.fiberGoal,
      'calories': state.settings.caloriesGoal,
      'resetHour': state.settings.resetHour,
      'updatedAt': state.settings.updatedAt?.millisecondsSinceEpoch,
    },
  });
}

/// True when [a] holds anything [b] doesn't (so the merge is worth pushing).
bool syncStateDiffers(SyncState a, SyncState b) =>
    canonicalSyncJson(a) != canonicalSyncJson(b);
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/sync_merge_test.dart`
Expected: `+21: All tests passed!`

Then `flutter analyze` → `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/services/sync_merge.dart test/sync_merge_test.dart
git commit -m "feat(sync): merge rules for items, favourites and settings"
```

---

### Task 2: Payload and local store

Two thin layers around Task 1: the codec that talks to iCloud's flat payload, and the store that reads and writes SharedPreferences and records what changed here.

**Files:**
- Create: `lib/services/sync_payload.dart`, `lib/services/sync_store.dart`
- Modify: `lib/config/storage_keys.dart`
- Test: `test/sync_payload_test.dart`, `test/sync_store_test.dart`

**Interfaces:**
- Consumes: everything Task 1 produced.
- Produces: `encodeSyncPayload(SyncState, {required DateTime timestamp}) → Map<String, dynamic>`; `decodeSyncPayload(Map<String, dynamic>) → SyncState`; `parseFoodItems(Object?)`, `parseIdList(Object?)`, `parseFavoriteChanges(Object?)`; `SyncStore({DateTime Function()? clock})` with `read(String dayKey)`, `write(SyncState)`, `recordItemsDeleted(Iterable<String>)`, `recordItemRestored(String)`, `clearDay()`, `recordFavoriteAdded(String)`, `recordFavoriteRemoved(String)`, `recordFavoritesCleared(Iterable<FoodItem>)`, `markSettingsChanged()`; `StorageKeys.foodItemsDeleted`, `StorageKeys.savedFoodsChanges`, `StorageKeys.settingsUpdatedAt`.

- [ ] **Step 1: Add the keys**

In `lib/config/storage_keys.dart`:

**Edit 1 of 2 — replace:**

```dart

  // HomeWidget / UserDefaults keys (shared with native iOS)
  static const String widgetTotalCarbs = 'totalCarbs';
  static const String widgetLastFoodName = 'lastFoodName';
  static const String widgetLastFoodCarbs = 'lastFoodCarbs';
  static const String widgetDailyCarbGoal = 'dailyCarbGoal';
  static const String widgetSiriLoggedItems = 'siriLoggedItems';
  static const String widgetFlutterTotalCarbs = 'flutter.total_carbs';
  // The day the widget totals belong to (lib/utils/day_key.dart) and the
  // user's reset hour, so Siri and the widget can tell a new day has started.
  static const String widgetDayKey = 'dayKey';
  static const String widgetResetHour = 'dailyResetHour';
```

**with:**

```dart

  // HomeWidget / UserDefaults keys (shared with native iOS)
  static const String widgetTotalCarbs = 'totalCarbs';
  static const String widgetLastFoodName = 'lastFoodName';
  static const String widgetLastFoodCarbs = 'lastFoodCarbs';
  static const String widgetDailyCarbGoal = 'dailyCarbGoal';
  // Written by Siri (CarbDataStore.addFood) and taken by the app through
  // com.carpecarb/siribuffer, not read from here — see SiriBufferService.
  static const String widgetSiriLoggedItems = 'siriLoggedItems';
  static const String widgetFlutterTotalCarbs = 'flutter.total_carbs';
  // The day the widget totals belong to (lib/utils/day_key.dart) and the
  // user's reset hour, so Siri and the widget can tell a new day has started.
  static const String widgetDayKey = 'dayKey';
  static const String widgetResetHour = 'dailyResetHour';
```

**Edit 2 of 2 — replace:**

```dart
  static const String fatGoal = 'fat_goal';
  static const String fiberGoal = 'fiber_goal';
  static const String caloriesGoal = 'calories_goal';

  // Cloud sync
  static const String cloudLastModified = 'cloud_last_modified';

  // Disclaimer
  static const String disclaimerAccepted = 'disclaimer_accepted';

  // Daily AI lookup quota, cached from the server's `quota` response
  // (free users: 4/day, enforced by getMultipleCarbCounts)
```

**with:**

```dart
  static const String fatGoal = 'fat_goal';
  static const String fiberGoal = 'fiber_goal';
  static const String caloriesGoal = 'calories_goal';

  // Cloud sync
  static const String cloudLastModified = 'cloud_last_modified';
  // Ids deleted today, so a delete isn't undone by another device's copy.
  // Cleared with food_items on a new day.
  static const String foodItemsDeleted = 'food_items_deleted';
  // Favourite key (lower-cased name) -> {updatedAt, deleted}: the most recent
  // add or delete, so the newer one wins when devices merge.
  static const String savedFoodsChanges = 'saved_foods_changes';
  // When the user last changed goals or the reset hour on this device.
  static const String settingsUpdatedAt = 'settings_updated_at';

  // Disclaimer
  static const String disclaimerAccepted = 'disclaimer_accepted';

  // Daily AI lookup quota, cached from the server's `quota` response
  // (free users: 4/day, enforced by getMultipleCarbCounts)
```


(The second edit is a note on an existing key; it belongs to Task 6 but is harmless here — leave it out if you prefer, Task 6 does not depend on it.)

- [ ] **Step 2: Write the failing tests**

Create `test/sync_payload_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/sync_merge.dart';
import 'package:carb_tracker/services/sync_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final loggedAt = DateTime(2026, 9, 20, 8, 30);
  final changedAt = DateTime(2026, 9, 20, 9);
  final pushedAt = DateTime(2026, 9, 20, 12);

  final state = SyncState(
    dayKey: '2026-09-20',
    items: [FoodItem(id: 'a', name: 'Apple', carbs: 25, loggedAt: loggedAt)],
    deletedItemIds: const {'b', 'c'},
    favorites: [
      FoodItem(id: 'f1', name: 'Bagel', carbs: 48, loggedAt: loggedAt)
    ],
    favoriteChanges: {
      'bagel': FavoriteChange(updatedAt: changedAt, deleted: false)
    },
    settings: SyncSettings(
      dailyCarbGoal: 100,
      proteinGoal: 60,
      resetHour: 4,
      updatedAt: changedAt,
    ),
  );

  test('encode then decode round-trips everything that syncs', () {
    final decoded =
        decodeSyncPayload(encodeSyncPayload(state, timestamp: pushedAt));

    expect(decoded.dayKey, '2026-09-20');
    expect(decoded.items.single.name, 'Apple');
    expect(decoded.items.single.loggedAt, loggedAt);
    expect(decoded.deletedItemIds, {'b', 'c'});
    expect(decoded.favorites.single.name, 'Bagel');
    expect(decoded.favoriteChanges['bagel']!.updatedAt, changedAt);
    expect(decoded.favoriteChanges['bagel']!.deleted, isFalse);
    expect(decoded.settings.dailyCarbGoal, 100);
    expect(decoded.settings.proteinGoal, 60);
    expect(decoded.settings.fatGoal, isNull);
    expect(decoded.settings.resetHour, 4);
    expect(decoded.settings.updatedAt, changedAt);
  });

  test('a re-encoded payload is identical, so pushing back settles', () {
    final first = encodeSyncPayload(state, timestamp: pushedAt);
    final second =
        encodeSyncPayload(decodeSyncPayload(first), timestamp: pushedAt);
    expect(second, first);
  });

  test('the payload carries the push timestamp for the native pull', () {
    final payload = encodeSyncPayload(state, timestamp: pushedAt);
    expect(payload[StorageKeys.cloudLastModified], pushedAt.toIso8601String());
  });

  test('an unset goal is sent as 0 and read back as unset', () {
    final payload = encodeSyncPayload(
      SyncState(
        dayKey: '2026-09-20',
        items: const [],
        deletedItemIds: const {},
        favorites: const [],
        favoriteChanges: const {},
        settings: const SyncSettings(),
      ),
      timestamp: pushedAt,
    );
    expect(payload[StorageKeys.dailyCarbGoal], 0.0);
    expect(decodeSyncPayload(payload).settings.dailyCarbGoal, isNull);
  });

  test(
      'a payload from an older build decodes with no deletes and stale settings',
      () {
    final decoded = decodeSyncPayload({
      StorageKeys.foodItems: jsonEncode([
        FoodItem(id: 'a', name: 'Apple', carbs: 25, loggedAt: loggedAt)
            .toJson(),
      ]),
      StorageKeys.savedFoods: jsonEncode([
        FoodItem(id: 'f1', name: 'Bagel', carbs: 48, loggedAt: loggedAt)
            .toJson(),
      ]),
      StorageKeys.dailyCarbGoal: 100.0,
      StorageKeys.dailyResetHour: 0,
      StorageKeys.lastSaveDate: '2026-09-20',
      StorageKeys.cloudLastModified: pushedAt.toIso8601String(),
    });

    expect(decoded.items.single.name, 'Apple');
    expect(decoded.deletedItemIds, isEmpty);
    expect(decoded.favorites.single.name, 'Bagel');
    expect(decoded.favoriteChanges, isEmpty);
    expect(decoded.settings.dailyCarbGoal, 100);
    // Epoch 0: any real change on this device beats the old build's settings.
    expect(decoded.settings.updatedAt, DateTime.fromMillisecondsSinceEpoch(0));
  });

  test('an empty payload decodes to an empty state rather than throwing', () {
    final decoded = decodeSyncPayload(const {});
    expect(decoded.dayKey, '');
    expect(decoded.items, isEmpty);
    expect(decoded.favorites, isEmpty);
    expect(decoded.settings.resetHour, 0);
  });

  test('a section that cannot be parsed is skipped, not fatal', () {
    final decoded = decodeSyncPayload({
      StorageKeys.foodItems: 'not json',
      StorageKeys.foodItemsDeleted: jsonEncode({'not': 'a list'}),
      StorageKeys.savedFoodsChanges: jsonEncode({'bagel': 'not a change'}),
      StorageKeys.savedFoods: jsonEncode([
        FoodItem(id: 'f1', name: 'Bagel', carbs: 48, loggedAt: loggedAt)
            .toJson(),
      ]),
      StorageKeys.lastSaveDate: '2026-09-20',
    });

    expect(decoded.items, isEmpty);
    expect(decoded.deletedItemIds, isEmpty);
    expect(decoded.favoriteChanges, isEmpty);
    expect(decoded.favorites.single.name, 'Bagel');
  });
}
```

Create `test/sync_store_test.dart`:

```dart
import 'dart:convert';

import 'package:carb_tracker/config/storage_keys.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/sync_merge.dart';
import 'package:carb_tracker/services/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const today = '2026-09-20';
  final loggedAt = DateTime(2026, 9, 20, 8, 30);
  final clock = DateTime(2026, 9, 20, 12);
  final store = SyncStore(clock: () => clock);

  FoodItem item(String id, String name) =>
      FoodItem(id: id, name: name, carbs: 20, loggedAt: loggedAt);

  String itemsJson(List<FoodItem> items) =>
      jsonEncode(items.map((f) => f.toJson()).toList());

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  group('read', () {
    test('reads today\'s items, favourites and settings', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.foodItems: itemsJson([item('a', 'Apple')]),
        StorageKeys.lastSaveDate: today,
        StorageKeys.foodItemsDeleted: jsonEncode(['b']),
        StorageKeys.savedFoods: itemsJson([item('f1', 'Bagel')]),
        StorageKeys.savedFoodsChanges: jsonEncode({
          'bagel': FavoriteChange(updatedAt: loggedAt, deleted: false).toJson()
        }),
        StorageKeys.dailyCarbGoal: 100.0,
        StorageKeys.dailyResetHour: 4,
        StorageKeys.settingsUpdatedAt: loggedAt.millisecondsSinceEpoch,
      });

      final state = await store.read(today);

      expect(state.items.single.name, 'Apple');
      expect(state.deletedItemIds, {'b'});
      expect(state.favorites.single.name, 'Bagel');
      expect(state.favoriteChanges['bagel']!.updatedAt, loggedAt);
      expect(state.settings.dailyCarbGoal, 100);
      expect(state.settings.resetHour, 4);
      expect(state.settings.updatedAt, loggedAt);
    });

    test('ignores items and deletes stored for an earlier day', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.foodItems: itemsJson([item('a', 'Apple')]),
        StorageKeys.lastSaveDate: '2026-09-19',
        StorageKeys.foodItemsDeleted: jsonEncode(['b']),
        StorageKeys.savedFoods: itemsJson([item('f1', 'Bagel')]),
      });

      final state = await store.read(today);

      expect(state.items, isEmpty);
      expect(state.deletedItemIds, isEmpty);
      // Favourites aren't tied to a day.
      expect(state.favorites.single.name, 'Bagel');
    });

    test('settings never changed here read as no timestamp', () async {
      final state = await store.read(today);
      expect(state.settings.updatedAt, isNull);
    });
  });

  group('write', () {
    test('saves the merged state, and read gives it back', () async {
      await store.write(SyncState(
        dayKey: today,
        items: [item('a', 'Apple')],
        deletedItemIds: const {'b'},
        favorites: [item('f1', 'Bagel')],
        favoriteChanges: {
          'bagel': FavoriteChange(updatedAt: loggedAt, deleted: false)
        },
        settings: SyncSettings(
          dailyCarbGoal: 100,
          resetHour: 4,
          updatedAt: loggedAt,
        ),
      ));

      final state = await store.read(today);

      expect(state.items.single.name, 'Apple');
      expect(state.deletedItemIds, {'b'});
      expect(state.favorites.single.name, 'Bagel');
      expect(state.favoriteChanges['bagel']!.updatedAt, loggedAt);
      expect(state.settings.dailyCarbGoal, 100);
      expect(state.settings.resetHour, 4);
      expect((await prefs()).getString(StorageKeys.lastSaveDate), today);
    });

    test('a goal the merge cleared is removed, not stored as 0', () async {
      SharedPreferences.setMockInitialValues({StorageKeys.proteinGoal: 60.0});

      await store.write(SyncState(
        dayKey: today,
        items: const [],
        deletedItemIds: const {},
        favorites: const [],
        favoriteChanges: const {},
        settings: const SyncSettings(),
      ));

      expect((await prefs()).getDouble(StorageKeys.proteinGoal), isNull);
    });

    test('leaves the settings timestamp alone when the merge has none',
        () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.settingsUpdatedAt: loggedAt.millisecondsSinceEpoch,
      });

      await store.write(SyncState(
        dayKey: today,
        items: const [],
        deletedItemIds: const {},
        favorites: const [],
        favoriteChanges: const {},
        settings: const SyncSettings(),
      ));

      expect((await prefs()).getInt(StorageKeys.settingsUpdatedAt),
          loggedAt.millisecondsSinceEpoch);
    });
  });

  group('recording local changes', () {
    test('deleted ids accumulate and undo removes one again', () async {
      SharedPreferences.setMockInitialValues({StorageKeys.lastSaveDate: today});

      await store.recordItemsDeleted(['a']);
      await store.recordItemsDeleted(['b', 'c']);
      expect((await store.read(today)).deletedItemIds, {'a', 'b', 'c'});

      await store.recordItemRestored('b');
      expect((await store.read(today)).deletedItemIds, {'a', 'c'});
    });

    test('clearDay drops today\'s items and their delete markers', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.foodItems: itemsJson([item('a', 'Apple')]),
        StorageKeys.lastSaveDate: today,
        StorageKeys.foodItemsDeleted: jsonEncode(['b']),
      });

      await store.clearDay();

      expect((await prefs()).getString(StorageKeys.foodItems), isNull);
      expect((await prefs()).getString(StorageKeys.foodItemsDeleted), isNull);
    });

    test('a favourite add and a remove are keyed by lower-cased name',
        () async {
      await store.recordFavoriteAdded('Bagel');
      await store.recordFavoriteRemoved('Greek Yogurt');

      final changes = (await store.read(today)).favoriteChanges;
      expect(changes['bagel']!.deleted, isFalse);
      expect(changes['bagel']!.updatedAt, clock);
      expect(changes['greek yogurt']!.deleted, isTrue);
    });

    test('re-adding a removed favourite records the newer add', () async {
      await store.recordFavoriteRemoved('Bagel');
      final later =
          SyncStore(clock: () => clock.add(const Duration(minutes: 5)));
      await later.recordFavoriteAdded('Bagel');

      final change = (await store.read(today)).favoriteChanges['bagel']!;
      expect(change.deleted, isFalse);
      expect(change.updatedAt, clock.add(const Duration(minutes: 5)));
    });

    test('resetting favourites records a delete for each one', () async {
      await store
          .recordFavoritesCleared([item('f1', 'Bagel'), item('f2', 'Apple')]);

      final changes = (await store.read(today)).favoriteChanges;
      expect(changes['bagel']!.deleted, isTrue);
      expect(changes['apple']!.deleted, isTrue);
    });

    test('markSettingsChanged stamps now', () async {
      await store.markSettingsChanged();
      expect((await store.read(today)).settings.updatedAt, clock);
    });
  });
}
```

- [ ] **Step 3: Run them and watch them fail**

Run: `flutter test test/sync_payload_test.dart test/sync_store_test.dart`
Expected: both fail to compile — the two services don't exist yet.

- [ ] **Step 4: Write the codec**

Create `lib/services/sync_payload.dart`:

```dart
import 'dart:convert';

import '../config/storage_keys.dart';
import '../models/food_item.dart';
import 'sync_merge.dart';

/// Converts between a [SyncState] and the flat key-value payload that goes in
/// and out of iCloud (NSUbiquitousKeyValueStore, via CloudSyncStore.swift).
///
/// Payloads written by builds before delete tracking have no
/// `food_items_deleted`, `saved_foods_changes` or `settings_updated_at`; those
/// read as "nothing deleted", "no changes recorded" and "changed long ago", so
/// an updated device still merges with them sensibly.

Map<String, dynamic> encodeSyncPayload(SyncState state,
    {required DateTime timestamp}) {
  String itemsJson(List<FoodItem> items) =>
      jsonEncode(items.map((f) => f.toJson()).toList());

  return {
    StorageKeys.foodItems: itemsJson(state.items),
    StorageKeys.foodItemsDeleted:
        jsonEncode(state.deletedItemIds.toList()..sort()),
    StorageKeys.savedFoods: itemsJson(state.favorites),
    StorageKeys.savedFoodsChanges: jsonEncode({
      for (final entry in state.favoriteChanges.entries)
        entry.key: entry.value.toJson(),
    }),
    StorageKeys.dailyCarbGoal: state.settings.dailyCarbGoal ?? 0.0,
    StorageKeys.proteinGoal: state.settings.proteinGoal ?? 0.0,
    StorageKeys.fatGoal: state.settings.fatGoal ?? 0.0,
    StorageKeys.fiberGoal: state.settings.fiberGoal ?? 0.0,
    StorageKeys.caloriesGoal: state.settings.caloriesGoal ?? 0.0,
    StorageKeys.dailyResetHour: state.settings.resetHour,
    StorageKeys.settingsUpdatedAt:
        state.settings.updatedAt?.millisecondsSinceEpoch ?? 0,
    StorageKeys.lastSaveDate: state.dayKey,
    StorageKeys.cloudLastModified: timestamp.toIso8601String(),
  };
}

SyncState decodeSyncPayload(Map<String, dynamic> data) {
  final settingsAt = data[StorageKeys.settingsUpdatedAt];
  return SyncState(
    dayKey: data[StorageKeys.lastSaveDate] is String
        ? data[StorageKeys.lastSaveDate] as String
        : '',
    items: parseFoodItems(data[StorageKeys.foodItems]),
    deletedItemIds: parseIdList(data[StorageKeys.foodItemsDeleted]),
    favorites: parseFoodItems(data[StorageKeys.savedFoods]),
    favoriteChanges: parseFavoriteChanges(data[StorageKeys.savedFoodsChanges]),
    settings: SyncSettings(
      dailyCarbGoal: _goal(data[StorageKeys.dailyCarbGoal]),
      proteinGoal: _goal(data[StorageKeys.proteinGoal]),
      fatGoal: _goal(data[StorageKeys.fatGoal]),
      fiberGoal: _goal(data[StorageKeys.fiberGoal]),
      caloriesGoal: _goal(data[StorageKeys.caloriesGoal]),
      resetHour: data[StorageKeys.dailyResetHour] is num
          ? (data[StorageKeys.dailyResetHour] as num).toInt()
          : 0,
      // A payload from an older build has no timestamp: treat its settings as
      // changed long ago, so a device that never changed its own adopts them.
      updatedAt: settingsAt is num
          ? DateTime.fromMillisecondsSinceEpoch(settingsAt.toInt())
          : DateTime.fromMillisecondsSinceEpoch(0),
    ),
  );
}

/// Parses a JSON list of food items, skipping anything malformed.
List<FoodItem> parseFoodItems(Object? json) {
  if (json is! String || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => FoodItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Parses a JSON list of item ids.
Set<String> parseIdList(Object? json) {
  if (json is! String || json.isEmpty) return const {};
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const {};
    return decoded.whereType<String>().toSet();
  } catch (_) {
    return const {};
  }
}

/// Parses the favourite change map, skipping anything malformed.
Map<String, FavoriteChange> parseFavoriteChanges(Object? json) {
  if (json is! String || json.isEmpty) return const {};
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return const {};
    final changes = <String, FavoriteChange>{};
    decoded.forEach((key, value) {
      final change = FavoriteChange.fromJson(value);
      if (key is String && change != null) changes[key] = change;
    });
    return changes;
  } catch (_) {
    return const {};
  }
}

double? _goal(Object? value) {
  if (value is! num) return null;
  final goal = value.toDouble();
  return goal > 0 ? goal : null;
}
```

- [ ] **Step 5: Write the store**

Create `lib/services/sync_store.dart`:

```dart
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_keys.dart';
import '../models/food_item.dart';
import 'sync_merge.dart';
import 'sync_payload.dart';

/// Reads and writes the synced state in SharedPreferences, and records the
/// local changes that merging needs to know about (what was deleted, when
/// favourites changed, when settings changed).
class SyncStore {
  SyncStore({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// This device's state for [dayKey]. Food items are only today's: a stored
  /// list from an earlier day is ignored, the same way the app does on launch.
  Future<SyncState> read(String dayKey) async {
    final prefs = await _prefs;
    final storedDay = prefs.getString(StorageKeys.lastSaveDate);
    final isToday = storedDay == dayKey;
    return SyncState(
      dayKey: dayKey,
      items: isToday
          ? parseFoodItems(prefs.getString(StorageKeys.foodItems))
          : const [],
      deletedItemIds: isToday
          ? parseIdList(prefs.getString(StorageKeys.foodItemsDeleted))
          : const {},
      favorites: parseFoodItems(prefs.getString(StorageKeys.savedFoods)),
      favoriteChanges:
          parseFavoriteChanges(prefs.getString(StorageKeys.savedFoodsChanges)),
      settings: SyncSettings(
        dailyCarbGoal: prefs.getDouble(StorageKeys.dailyCarbGoal),
        proteinGoal: prefs.getDouble(StorageKeys.proteinGoal),
        fatGoal: prefs.getDouble(StorageKeys.fatGoal),
        fiberGoal: prefs.getDouble(StorageKeys.fiberGoal),
        caloriesGoal: prefs.getDouble(StorageKeys.caloriesGoal),
        resetHour: prefs.getInt(StorageKeys.dailyResetHour) ?? 0,
        // Absent means this device has never changed its settings, so the
        // cloud's win however old they are.
        updatedAt: _readSettingsUpdatedAt(prefs),
      ),
    );
  }

  /// Saves a merged state: items and favourites, what was deleted, and the
  /// settings that won.
  Future<void> write(SyncState state) async {
    final prefs = await _prefs;
    await prefs.setString(StorageKeys.foodItems,
        jsonEncode(state.items.map((f) => f.toJson()).toList()));
    await prefs.setString(StorageKeys.lastSaveDate, state.dayKey);
    await _writeIds(prefs, state.deletedItemIds);
    await prefs.setString(StorageKeys.savedFoods,
        jsonEncode(state.favorites.map((f) => f.toJson()).toList()));
    await _writeChanges(prefs, state.favoriteChanges);
    await _writeGoal(
        prefs, StorageKeys.dailyCarbGoal, state.settings.dailyCarbGoal);
    await _writeGoal(
        prefs, StorageKeys.proteinGoal, state.settings.proteinGoal);
    await _writeGoal(prefs, StorageKeys.fatGoal, state.settings.fatGoal);
    await _writeGoal(prefs, StorageKeys.fiberGoal, state.settings.fiberGoal);
    await _writeGoal(
        prefs, StorageKeys.caloriesGoal, state.settings.caloriesGoal);
    await prefs.setInt(StorageKeys.dailyResetHour, state.settings.resetHour);
    final updatedAt = state.settings.updatedAt;
    if (updatedAt != null) {
      await prefs.setInt(
          StorageKeys.settingsUpdatedAt, updatedAt.millisecondsSinceEpoch);
    }
  }

  /// Marks items as deleted today so another device's copy doesn't restore them.
  Future<void> recordItemsDeleted(Iterable<String> ids) async {
    final prefs = await _prefs;
    await _writeIds(prefs, {
      ...parseIdList(prefs.getString(StorageKeys.foodItemsDeleted)),
      ...ids
    });
  }

  /// Undo: the item is wanted again, so drop its delete marker.
  Future<void> recordItemRestored(String id) async {
    final prefs = await _prefs;
    await _writeIds(prefs,
        parseIdList(prefs.getString(StorageKeys.foodItemsDeleted))..remove(id));
  }

  /// Clears today's items and their delete markers (a new day starts fresh).
  Future<void> clearDay() async {
    final prefs = await _prefs;
    await prefs.remove(StorageKeys.foodItems);
    await prefs.remove(StorageKeys.foodItemsDeleted);
  }

  Future<void> recordFavoriteAdded(String name) =>
      _recordFavorite(name, deleted: false);

  Future<void> recordFavoriteRemoved(String name) =>
      _recordFavorite(name, deleted: true);

  Future<void> recordFavoritesCleared(Iterable<FoodItem> favorites) async {
    for (final favorite in favorites) {
      await _recordFavorite(favorite.name, deleted: true);
    }
  }

  /// Records that the user changed goals or the reset hour here, so this
  /// device's settings win over older ones from another device.
  Future<void> markSettingsChanged() async {
    final prefs = await _prefs;
    await prefs.setInt(
        StorageKeys.settingsUpdatedAt, _clock().millisecondsSinceEpoch);
  }

  Future<void> _recordFavorite(String name, {required bool deleted}) async {
    final prefs = await _prefs;
    final changes = {
      ...parseFavoriteChanges(prefs.getString(StorageKeys.savedFoodsChanges)),
      favoriteKey(name): FavoriteChange(updatedAt: _clock(), deleted: deleted),
    };
    await _writeChanges(prefs, changes);
  }

  DateTime? _readSettingsUpdatedAt(SharedPreferences prefs) {
    final ms = prefs.getInt(StorageKeys.settingsUpdatedAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> _writeIds(SharedPreferences prefs, Set<String> ids) =>
      prefs.setString(
          StorageKeys.foodItemsDeleted, jsonEncode(ids.toList()..sort()));

  Future<void> _writeChanges(
          SharedPreferences prefs, Map<String, FavoriteChange> changes) =>
      prefs.setString(
          StorageKeys.savedFoodsChanges,
          jsonEncode(
              {for (final e in changes.entries) e.key: e.value.toJson()}));

  Future<void> _writeGoal(SharedPreferences prefs, String key, double? value) =>
      value == null ? prefs.remove(key) : prefs.setDouble(key, value);
}
```

- [ ] **Step 6: Run the tests**

Run: `flutter test test/sync_payload_test.dart test/sync_store_test.dart`
Expected: `+19: All tests passed!` (7 payload, 12 store)

Then `flutter analyze && flutter test` → `No issues found!` and all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/config/storage_keys.dart lib/services/sync_payload.dart lib/services/sync_store.dart test/sync_payload_test.dart test/sync_store_test.dart
git commit -m "feat(sync): payload and local store for the merge"
```

---

### Task 3: Native — deliver remote changes, report failed pushes

Three bugs in one file plus its channel: the timestamp comparison that never fires, the three new keys a pull would otherwise drop, and a push that always claimed success.

**Files:**
- Modify: `ios/CarbShared/Sources/CarbShared/CloudSyncStore.swift`, `ios/Runner/CloudSyncChannel.swift`
- Test: `ios/CarbShared/Tests/CarbSharedTests/CloudSyncStoreTests.swift` (create)

**Interfaces:**
- Produces: `KeyValueStoring` (protocol: `set(_:forKey:)`, `object(forKey:)`, `string(forKey:)`, `synchronize()`), with `NSUbiquitousKeyValueStore` conforming; `CloudSyncStore.init(kvStore:isAvailable:)`; `pushToCloud(_:) -> Bool`; `static CloudSyncStore.isNewRemoteChange(previous:pulled:) -> Bool`. `CloudSyncStore.shared` keeps its current meaning (iCloud's own store).

- [ ] **Step 1: Write the failing tests**

Create `ios/CarbShared/Tests/CarbSharedTests/CloudSyncStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import CarbShared

/// An in-memory stand-in for NSUbiquitousKeyValueStore: the real one needs a
/// signed-in iCloud account, which a test machine doesn't have.
final class FakeKeyValueStore: KeyValueStoring {
    var values: [String: Any] = [:]
    var synchronizeResult = true
    private(set) var synchronizeCount = 0

    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }

    @discardableResult
    func synchronize() -> Bool {
        synchronizeCount += 1
        return synchronizeResult
    }
}

@MainActor
struct CloudSyncStoreTests {
    private let kvStore = FakeKeyValueStore()

    private func store(available: Bool = true) -> CloudSyncStore {
        CloudSyncStore(kvStore: kvStore, isAvailable: { available })
    }

    // MARK: - Push

    @Test func pushWritesEveryKeyAndReportsSuccess() {
        let pushed = store().pushToCloud([
            "food_items": "[]",
            "food_items_deleted": "[\"a\"]",
            "cloud_last_modified": "2026-09-20T12:00:00Z",
        ])

        #expect(pushed)
        #expect(kvStore.values["food_items"] as? String == "[]")
        #expect(kvStore.values["food_items_deleted"] as? String == "[\"a\"]")
        #expect(kvStore.values["cloud_last_modified"] as? String == "2026-09-20T12:00:00Z")
    }

    @Test func pushFailsWhenICloudIsUnavailable() {
        let pushed = store(available: false).pushToCloud(["food_items": "[]"])

        #expect(!pushed)
        #expect(kvStore.values.isEmpty)
        #expect(kvStore.synchronizeCount == 0)
    }

    @Test func pushFailsWhenThereIsNothingToPush() {
        #expect(!store().pushToCloud([:]))
    }

    @Test func pushFailsWhenTheStoreWillNotSynchronize() {
        kvStore.synchronizeResult = false

        #expect(!store().pushToCloud(["food_items": "[]"]))
    }

    // MARK: - Pull

    @Test func pullReturnsTheDeleteAndChangeKeysTheMergeNeeds() {
        kvStore.values = [
            "cloud_last_modified": "2026-09-20T12:00:00Z",
            "food_items": "[]",
            "food_items_deleted": "[\"a\"]",
            "saved_foods_changes": "{\"bagel\":{\"updatedAt\":1,\"deleted\":true}}",
            "settings_updated_at": 1_758_000_000_000,
            "not_a_synced_key": "ignored",
        ]

        let pulled = try? #require(store().pullFromCloud())

        #expect(pulled?["food_items_deleted"] as? String == "[\"a\"]")
        #expect(pulled?["saved_foods_changes"] as? String
            == "{\"bagel\":{\"updatedAt\":1,\"deleted\":true}}")
        #expect(pulled?["settings_updated_at"] as? Int == 1_758_000_000_000)
        #expect(pulled?["not_a_synced_key"] == nil)
    }

    @Test func pullReturnsNothingWhenICloudHasNoDataYet() {
        #expect(store().pullFromCloud() == nil)
    }

    @Test func pullReturnsNothingWhenICloudIsUnavailable() {
        kvStore.values["cloud_last_modified"] = "2026-09-20T12:00:00Z"

        #expect(store(available: false).pullFromCloud() == nil)
    }

    // MARK: - Remote changes

    @Test func aTimestampThisDeviceHasNotSeenIsANewChange() {
        #expect(CloudSyncStore.isNewRemoteChange(
            previous: "2026-09-20T12:00:00Z", pulled: "2026-09-20T12:05:00Z"))
    }

    @Test func thisDevicesOwnPushIsNotANewChange() {
        #expect(!CloudSyncStore.isNewRemoteChange(
            previous: "2026-09-20T12:00:00Z", pulled: "2026-09-20T12:00:00Z"))
    }

    @Test func theFirstChangeSeenCountsAsNew() {
        #expect(CloudSyncStore.isNewRemoteChange(
            previous: nil, pulled: "2026-09-20T12:00:00Z"))
    }

    @Test func aChangeWithNoTimestampIsIgnored() {
        #expect(!CloudSyncStore.isNewRemoteChange(previous: nil, pulled: nil))
        #expect(!CloudSyncStore.isNewRemoteChange(previous: "2026-09-20T12:00:00Z", pulled: ""))
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd ios/CarbShared && swift test`
Expected: compile errors — no `KeyValueStoring`, no `CloudSyncStore(kvStore:isAvailable:)`, `pushToCloud` returns Void, no `isNewRemoteChange`.

- [ ] **Step 3: Change the store**

In `ios/CarbShared/Sources/CarbShared/CloudSyncStore.swift`:

**Edit 1 of 8 — replace:**

```swift
import Foundation
import os.log

/// Syncs app data across devices using NSUbiquitousKeyValueStore (iCloud key-value store).
/// Placed in CarbShared so all targets (app, widget, watch, Siri) can access it.
///
/// Data flows entirely through the MethodChannel: Flutter serializes data on push
/// and writes it back to SharedPreferences on pull. This avoids UserDefaults domain
/// mismatches between the Flutter SharedPreferences store and the App Group store.
```

**with:**

```swift
import Foundation
import os.log

/// The part of `NSUbiquitousKeyValueStore` that `CloudSyncStore` uses, so tests
/// can run against an in-memory double — the real store needs a signed-in
/// iCloud account and a provisioned entitlement.
public protocol KeyValueStoring: AnyObject {
    func set(_ value: Any?, forKey key: String)
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStoring {}

/// Syncs app data across devices using NSUbiquitousKeyValueStore (iCloud key-value store).
/// Placed in CarbShared so all targets (app, widget, watch, Siri) can access it.
///
/// Data flows entirely through the MethodChannel: Flutter serializes data on push
/// and writes it back to SharedPreferences on pull. This avoids UserDefaults domain
/// mismatches between the Flutter SharedPreferences store and the App Group store.
```

**Edit 2 of 8 — replace:**

```swift
    // MARK: - Singleton
    
    public static let shared = CloudSyncStore()
    
    // MARK: - Properties

    private let kvStore = NSUbiquitousKeyValueStore.default
    private let logger = Logger(subsystem: "com.carpecarb", category: "CloudSyncStore")
    private static let iso8601 = ISO8601DateFormatter()
    
    /// Keys synced to iCloud — must match StorageKeys in Dart
    private enum Key {
        static let foodItems = "food_items"
```

**with:**

```swift
    // MARK: - Singleton
    
    public static let shared = CloudSyncStore()
    
    // MARK: - Properties

    private let kvStore: any KeyValueStoring
    private let isAvailableCheck: () -> Bool
    private let logger = Logger(subsystem: "com.carpecarb", category: "CloudSyncStore")
    private static let iso8601 = ISO8601DateFormatter()
    
    /// Keys synced to iCloud — must match StorageKeys in Dart
    private enum Key {
        static let foodItems = "food_items"
```

**Edit 3 of 8 — replace:**

```swift
        static let lastSaveDate = "last_save_date"
        static let lastModified = "cloud_last_modified"
        static let proteinGoal = "protein_goal"
        static let fatGoal = "fat_goal"
        static let fiberGoal = "fiber_goal"
        static let caloriesGoal = "calories_goal"
    }

    /// All data keys (excluding the timestamp)
    private static let dataKeys = [
        Key.foodItems, Key.savedFoods, Key.dailyCarbGoal,
        Key.dailyResetHour, Key.lastSaveDate,
        Key.proteinGoal, Key.fatGoal, Key.fiberGoal, Key.caloriesGoal,
    ]

    /// Callback invoked when remote changes are detected
    /// Thread-safe: stored on MainActor
    private var onChange: (([String: Any]) -> Void)?
    
```

**with:**

```swift
        static let lastSaveDate = "last_save_date"
        static let lastModified = "cloud_last_modified"
        static let proteinGoal = "protein_goal"
        static let fatGoal = "fat_goal"
        static let fiberGoal = "fiber_goal"
        static let caloriesGoal = "calories_goal"
        static let foodItemsDeleted = "food_items_deleted"
        static let savedFoodsChanges = "saved_foods_changes"
        static let settingsUpdatedAt = "settings_updated_at"
    }

    /// All data keys (excluding the timestamp)
    private static let dataKeys = [
        Key.foodItems, Key.savedFoods, Key.dailyCarbGoal,
        Key.dailyResetHour, Key.lastSaveDate,
        Key.proteinGoal, Key.fatGoal, Key.fiberGoal, Key.caloriesGoal,
        // What was deleted and when things changed — a pull drops any key not
        // listed here, so leaving these out would strip the merge's evidence.
        Key.foodItemsDeleted, Key.savedFoodsChanges, Key.settingsUpdatedAt,
    ]

    /// Callback invoked when remote changes are detected
    /// Thread-safe: stored on MainActor
    private var onChange: (([String: Any]) -> Void)?
    
```

**Edit 4 of 8 — replace:**

```swift
    private var observing = false
    
    /// Track the last sync timestamp to detect changes
    /// Thread-safe: stored on MainActor
    private var lastKnownTimestamp: String?

    private init() {
        logger.info("CloudSyncStore initialized")
    }
    
    deinit {
        if observing {
            // Note: deinit is not async, so we do synchronous cleanup
```

**with:**

```swift
    private var observing = false
    
    /// Track the last sync timestamp to detect changes
    /// Thread-safe: stored on MainActor
    private var lastKnownTimestamp: String?

    /// - Parameters:
    ///   - kvStore: where synced values are read and written; iCloud's own
    ///     store by default.
    ///   - isAvailable: whether iCloud can be used. The default asks
    ///     `FileManager` for the ubiquity token, which is nil when the user is
    ///     signed out of iCloud.
    public init(
        kvStore: any KeyValueStoring = NSUbiquitousKeyValueStore.default,
        isAvailable: @escaping () -> Bool = {
            FileManager.default.ubiquityIdentityToken != nil
        }
    ) {
        self.kvStore = kvStore
        self.isAvailableCheck = isAvailable
        logger.info("CloudSyncStore initialized")
    }
    
    deinit {
        if observing {
            // Note: deinit is not async, so we do synchronous cleanup
```

**Edit 5 of 8 — replace:**

```swift

    // MARK: - Availability

    /// Checks if iCloud is available for this user
    /// Thread-safe: FileManager is thread-safe for this property
    public var isAvailable: Bool {
        let available = FileManager.default.ubiquityIdentityToken != nil
        logger.debug("iCloud availability checked: \(available)")
        return available
    }

    // MARK: - Push (Flutter → iCloud)

    /// Writes the data dict received from Flutter directly into iCloud KV store.
    /// Flutter is responsible for providing all syncable keys.
    ///
    /// - Parameter data: Dictionary of key-value pairs to sync
    /// - Note: Thread-safe. Can be called from any thread.
    public func pushToCloud(_ data: [String: Any]) {
        guard isAvailable else {
            logger.warning("Push aborted: iCloud not available")
            return
        }
        
        guard !data.isEmpty else {
            logger.warning("Push aborted: Empty data provided")
            return
        }

        // Use caller-supplied timestamp if present (so Flutter can track what
        // was pushed), otherwise generate one.
        let timestamp = (data[Key.lastModified] as? String)?.isEmpty == false
            ? data[Key.lastModified] as! String
```

**with:**

```swift

    // MARK: - Availability

    /// Checks if iCloud is available for this user
    /// Thread-safe: FileManager is thread-safe for this property
    public var isAvailable: Bool {
        let available = isAvailableCheck()
        logger.debug("iCloud availability checked: \(available)")
        return available
    }

    // MARK: - Push (Flutter → iCloud)

    /// Writes the data dict received from Flutter directly into iCloud KV store.
    /// Flutter is responsible for providing all syncable keys.
    ///
    /// - Parameter data: Dictionary of key-value pairs to sync
    /// - Returns: false when iCloud is unavailable, there was nothing to push,
    ///   or the store refused to synchronize. The app shows a failed sync and
    ///   retries on the next change, so this must not report success blindly.
    /// - Note: Thread-safe. Can be called from any thread.
    @discardableResult
    public func pushToCloud(_ data: [String: Any]) -> Bool {
        guard isAvailable else {
            logger.warning("Push aborted: iCloud not available")
            return false
        }
        
        guard !data.isEmpty else {
            logger.warning("Push aborted: Empty data provided")
            return false
        }

        // Use caller-supplied timestamp if present (so Flutter can track what
        // was pushed), otherwise generate one.
        let timestamp = (data[Key.lastModified] as? String)?.isEmpty == false
            ? data[Key.lastModified] as! String
```

**Edit 6 of 8 — replace:**

```swift
        
        if synced {
            logger.info("Successfully pushed to iCloud (timestamp: \(timestamp))")
        } else {
            logger.warning("Push completed but synchronize() returned false")
        }
    }

    // MARK: - Pull (iCloud → Flutter)

    /// Reads all data from iCloud KV store and returns it so Flutter can write
    /// it to SharedPreferences. Returns nil if iCloud is unavailable or empty.
```

**with:**

```swift
        
        if synced {
            logger.info("Successfully pushed to iCloud (timestamp: \(timestamp))")
        } else {
            logger.warning("Push completed but synchronize() returned false")
        }
        return synced
    }

    // MARK: - Pull (iCloud → Flutter)

    /// Reads all data from iCloud KV store and returns it so Flutter can write
    /// it to SharedPreferences. Returns nil if iCloud is unavailable or empty.
```

**Edit 7 of 8 — replace:**

```swift
    /// Called when NSUbiquitousKeyValueStore detects external changes
    /// - Note: This is called on a background thread by NotificationCenter
    @objc private func kvStoreDidChange(_ notification: Notification) {
        logger.debug("Received external change notification")
        
        // Verify the notification is from our store
        guard let store = notification.object as? NSUbiquitousKeyValueStore,
              store == kvStore else {
            logger.warning("Notification from unexpected store - ignoring")
            return
        }
        
        // Get the change reason
        if let changeReason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
```

**with:**

```swift
    /// Called when NSUbiquitousKeyValueStore detects external changes
    /// - Note: This is called on a background thread by NotificationCenter
    @objc private func kvStoreDidChange(_ notification: Notification) {
        logger.debug("Received external change notification")
        
        // Verify the notification is from our store
        guard let store = notification.object as AnyObject?,
              store === (kvStore as AnyObject) else {
            logger.warning("Notification from unexpected store - ignoring")
            return
        }
        
        // Get the change reason
        if let changeReason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
```

**Edit 8 of 8 — replace:**

```swift
            logger.debug("Changed keys: \(changedKeys.joined(separator: ", "))")
        }
        
        // Pull the latest data
        // MainActor isolated method called from background thread needs await
        Task { @MainActor in
            if let pulled = self.pullFromCloud() {
                // Only notify if timestamp changed (avoid duplicate notifications)
                if let newTimestamp = pulled[Key.lastModified] as? String,
                   newTimestamp != self.lastKnownTimestamp {
                    logger.info("Notifying of remote change")
                    self.onChange?(pulled)
                } else {
                    logger.debug("Skipping notification - timestamp unchanged")
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    /// Logs the change reason from the notification
    private func logChangeReason(_ reason: Int) {
        switch reason {
```

**with:**

```swift
            logger.debug("Changed keys: \(changedKeys.joined(separator: ", "))")
        }
        
        // Pull the latest data
        // MainActor isolated method called from background thread needs await
        Task { @MainActor in
            // Capture the timestamp before pulling: `pullFromCloud` overwrites
            // `lastKnownTimestamp`, so comparing after it always found them
            // equal — which is why remote changes never reached the app.
            let previous = self.lastKnownTimestamp
            if let pulled = self.pullFromCloud() {
                if Self.isNewRemoteChange(
                    previous: previous,
                    pulled: pulled[Key.lastModified] as? String
                ) {
                    self.logger.info("Notifying of remote change")
                    self.onChange?(pulled)
                } else {
                    self.logger.debug("Skipping notification - timestamp unchanged")
                }
            }
        }
    }

    /// Whether a pulled timestamp is a change this device hasn't seen yet.
    /// Pure, so the comparison can be tested without an iCloud account.
    public static func isNewRemoteChange(previous: String?, pulled: String?) -> Bool {
        guard let pulled, !pulled.isEmpty else { return false }
        return pulled != previous
    }
    
    // MARK: - Helpers
    
    /// Logs the change reason from the notification
    private func logChangeReason(_ reason: Int) {
        switch reason {
```


- [ ] **Step 4: Return the result over the channel**

In `ios/Runner/CloudSyncChannel.swift`:

**Edit 1 of 1 — replace:**

```swift
            } else {
                logger.debug("   \(key): \(type(of: value))")
            }
        }
        
        Task { @MainActor in
            CloudSyncStore.shared.pushToCloud(data)
            self.logger.info("✓ pushToCloud: Completed")
            result(true)
        }
    }
    
    private func handlePullFromCloud(result: @escaping FlutterResult) {
        logger.info("⬇️  pullFromCloud: Requesting data from iCloud")
        
```

**with:**

```swift
            } else {
                logger.debug("   \(key): \(type(of: value))")
            }
        }
        
        Task { @MainActor in
            // Report what actually happened: answering true regardless made the
            // app show a synced icon after a push that iCloud never took.
            let pushed = CloudSyncStore.shared.pushToCloud(data)
            self.logger.info("\(pushed ? "✓" : "✗") pushToCloud: Completed (pushed: \(pushed))")
            result(pushed)
        }
    }
    
    private func handlePullFromCloud(result: @escaping FlutterResult) {
        logger.info("⬇️  pullFromCloud: Requesting data from iCloud")
        
```


- [ ] **Step 5: Run the tests and the build**

Run: `cd ios/CarbShared && swift test`
Expected: `Test run with 37 tests in 6 suites passed` (11 of them new).

Run the iOS build command from the Global Constraints.
Expected: `** BUILD SUCCEEDED **` with no new warnings.

- [ ] **Step 6: Commit**

```bash
git add ios/CarbShared/Sources/CarbShared/CloudSyncStore.swift ios/CarbShared/Tests/CarbSharedTests/CloudSyncStoreTests.swift ios/Runner/CloudSyncChannel.swift
git commit -m "fix(sync): deliver remote changes and report failed pushes"
```

---

### Task 4: Native — take the Siri buffer in one step

The app reads the App Group buffer and clears it in two calls; a Siri log that lands in between is overwritten. One main-actor method, exposed on its own channel.

**Files:**
- Modify: `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift`, `ios/Runner/AppDelegate.swift`, `ios/Runner.xcodeproj/project.pbxproj`
- Create: `ios/Runner/SiriBufferChannel.swift`
- Test: `ios/CarbShared/Tests/CarbSharedTests/CarbDataStoreTests.swift`

**Interfaces:**
- Produces: `@MainActor CarbDataStore.takeSiriLoggedItems() -> String?`; the channel `com.carpecarb/siribuffer` with method `takeLoggedItems`, which Task 6's Dart side calls.

- [ ] **Step 1: Write the failing tests**

Append to `ios/CarbShared/Tests/CarbSharedTests/CarbDataStoreTests.swift` (inside the struct, after the last test):

**Edit 1 of 1 — replace:**

```swift
        #expect(buffer[0]["protein"] as? Double == 25)
        #expect(buffer[0]["calories"] as? Double == 590)
        #expect(buffer[0]["citations"] as? [String] == ["https://example.com"])
        #expect(buffer[0]["loggedAt"] as? String == ISO8601DateFormatter().string(from: noon))
        #expect(buffer[1]["protein"] == nil)
    }
}
```

**with:**

```swift
        #expect(buffer[0]["protein"] as? Double == 25)
        #expect(buffer[0]["calories"] as? Double == 590)
        #expect(buffer[0]["citations"] as? [String] == ["https://example.com"])
        #expect(buffer[0]["loggedAt"] as? String == ISO8601DateFormatter().string(from: noon))
        #expect(buffer[1]["protein"] == nil)
    }

    @Test func takeSiriLoggedItemsReturnsTheBufferAndEmptiesIt() {
        store.addFood(LoggedFood(name: "Toast", carbs: 15), now: noon)

        let taken = store.takeSiriLoggedItems()

        #expect(taken?.contains("Toast") == true)
        #expect(defaults.string(forKey: CarbDataStore.Keys.siriLoggedItems) == nil)
        // A second take finds nothing, so nothing is imported twice.
        #expect(store.takeSiriLoggedItems() == nil)
    }

    @Test func takeSiriLoggedItemsReturnsNilWhenNothingIsWaiting() {
        #expect(store.takeSiriLoggedItems() == nil)
    }
}
```


- [ ] **Step 2: Run them and watch them fail**

Run: `cd ios/CarbShared && swift test`
Expected: compile error — `value of type 'CarbDataStore' has no member 'takeSiriLoggedItems'`.

- [ ] **Step 3: Add the method**

In `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift`:

**Edit 1 of 1 — replace:**

```swift

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
```

**with:**

```swift

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Hands the app the buffered Siri items and empties the buffer in one
    /// main-actor step, so an `addFood` can't land between the read and the
    /// clear and be dropped. Returns nil when nothing is waiting.
    ///
    /// The buffer is cleared before the app has parsed it: a buffer that can't
    /// be read, or one taken moments before the app is killed, is lost. That is
    /// the cost of closing the race, and anything `addFood` wrote parses.
    public func takeSiriLoggedItems() -> String? {
        guard let json = defaults?.string(forKey: Keys.siriLoggedItems),
              !json.isEmpty else {
            return nil
        }
        defaults?.removeObject(forKey: Keys.siriLoggedItems)
        return json
    }

    /// Items waiting for the app to import, as written by `addFood`.
    func siriLoggedItems() -> [[String: Any]] {
        guard let json = defaults?.string(forKey: Keys.siriLoggedItems),
              let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
```


- [ ] **Step 4: Run the tests**

Run: `cd ios/CarbShared && swift test`
Expected: `Test run with 39 tests in 6 suites passed`.

- [ ] **Step 5: Add the channel**

Create `ios/Runner/SiriBufferChannel.swift`:

```swift
import Flutter
import CarbShared
import os.log

/// Hands Flutter the Siri-logged items waiting in the App Group and empties the
/// buffer in the same step.
///
/// The app used to read the buffer with `home_widget` and clear it in a second
/// call; a Siri log that landed in between was overwritten and lost.
class SiriBufferChannel {
    static let channelName = "com.carpecarb/siribuffer"

    private let channel: FlutterMethodChannel
    private let logger = Logger(subsystem: "com.carpecarb", category: "SiriBufferChannel")

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "takeLoggedItems":
            Task { @MainActor in
                let items = CarbDataStore.shared.takeSiriLoggedItems()
                self.logger.info("takeLoggedItems: \(items == nil ? "buffer empty" : "handed over and cleared")")
                result(items)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
```

- [ ] **Step 6: Register it**

In `ios/Runner/AppDelegate.swift`:

**Edit 1 of 2 — replace:**

```swift
import CarbShared
import os.log

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cloudSyncChannel: CloudSyncChannel?
  private let logger = Logger(subsystem: "com.carpecarb", category: "AppDelegate")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
```

**with:**

```swift
import CarbShared
import os.log

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cloudSyncChannel: CloudSyncChannel?
  private var siriBufferChannel: SiriBufferChannel?
  private let logger = Logger(subsystem: "com.carpecarb", category: "AppDelegate")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
```

**Edit 2 of 2 — replace:**

```swift
    }
    
    logger.debug("✓ Plugin registrar obtained for CloudSyncChannel")
    
    cloudSyncChannel = CloudSyncChannel(messenger: registrar.messenger())
    logger.info("✓ CloudSyncChannel registered successfully")
  }
  
  override func applicationWillResignActive(_ application: UIApplication) {
    logger.info("📴 Application will resign active")
    super.applicationWillResignActive(application)
  }
```

**with:**

```swift
    }
    
    logger.debug("✓ Plugin registrar obtained for CloudSyncChannel")
    
    cloudSyncChannel = CloudSyncChannel(messenger: registrar.messenger())
    logger.info("✓ CloudSyncChannel registered successfully")

    siriBufferChannel = SiriBufferChannel(messenger: registrar.messenger())
    logger.info("✓ SiriBufferChannel registered successfully")
  }
  
  override func applicationWillResignActive(_ application: UIApplication) {
    logger.info("📴 Application will resign active")
    super.applicationWillResignActive(application)
  }
```


- [ ] **Step 7: Add the file to the Xcode project**

Run this from the repo root exactly as written — it asserts each anchor appears once and lints the result:

```bash
python3 - <<'PY'
p = 'ios/Runner.xcodeproj/project.pbxproj'
s = open(p).read()
pairs = [
("\t\tSI0001B3 /* SiriAuth.swift in Sources */ = {isa = PBXBuildFile; fileRef = SI0001A3 /* SiriAuth.swift */; };\n",
 "\t\tSI0001B4 /* SiriBufferChannel.swift in Sources */ = {isa = PBXBuildFile; fileRef = SI0001A4 /* SiriBufferChannel.swift */; };\n"),
("\t\tSI0001A3 /* SiriAuth.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SiriAuth.swift; sourceTree = \"<group>\"; };\n",
 "\t\tSI0001A4 /* SiriBufferChannel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SiriBufferChannel.swift; sourceTree = \"<group>\"; };\n"),
("\t\t\t\tSI0001A3 /* SiriAuth.swift */,\n",
 "\t\t\t\tSI0001A4 /* SiriBufferChannel.swift */,\n"),
("\t\t\t\tSI0001B3 /* SiriAuth.swift in Sources */,\n",
 "\t\t\t\tSI0001B4 /* SiriBufferChannel.swift in Sources */,\n"),
]
for anchor, added in pairs:
    assert s.count(anchor) == 1, anchor
    s = s.replace(anchor, anchor + added)
open(p, 'w').write(s)
PY
plutil -lint ios/Runner.xcodeproj/project.pbxproj
```

Expected: `ios/Runner.xcodeproj/project.pbxproj: OK`

- [ ] **Step 8: Build**

Run the iOS build command from the Global Constraints.
Expected: `** BUILD SUCCEEDED **` with no new warnings. If `SiriBufferChannel` is reported as an unknown type in `AppDelegate`, the pbxproj edit didn't land — re-run Step 7 rather than working around it.

- [ ] **Step 9: Commit**

```bash
git add ios/CarbShared/Sources/CarbShared/CarbDataStore.swift ios/CarbShared/Tests/CarbSharedTests/CarbDataStoreTests.swift ios/Runner/SiriBufferChannel.swift ios/Runner/AppDelegate.swift ios/Runner.xcodeproj/project.pbxproj
git commit -m "fix(siri): take the logged-items buffer in one step"
```

---

### Task 5: App wiring — merge on pull, push what changed

Replace the union-by-id merge in `main.dart` with Task 1's rules, record deletes where they happen, drop the timestamp gate that skipped remote changes, and give the AnimatedList a new key when the list is replaced wholesale.

**Files:**
- Modify: `lib/main.dart`, `lib/screens/settings_page.dart`, `lib/services/cloud_sync_service.dart`
- Test: `test/widget_test.dart`

**Interfaces:**
- Consumes: Tasks 1–3. `_pushToCloud(payload) → Future<bool>` already exists in `main.dart` and drives the sync icon; keep using it.
- Produces: `_pushLocalState()` (reads the store, encodes, pushes, advances `cloud_last_modified` only on success), `_saveAfterDeleting(List<String>)`, `_saveAfterRestoring(String)`.

- [ ] **Step 1: Write the failing tests**

In `test/widget_test.dart`, add the new group (the edit inserts it before the closing brace of `main()`):

**Edit 1 of 1 — replace:**

```dart
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 0.0);
      expect(state.foodItems, isEmpty);
    });
  });
}
```

**with:**

```dart
      await tester.pumpAndSettle();

      expect(state.totalCarbs, 0.0);
      expect(state.foodItems, isEmpty);
    });
  });

  group('iCloud sync', () {
    /// Three items today, of which the cloud says two were deleted on the
    /// other device.
    void seedThreeItemsToday() {
      SharedPreferences.setMockInitialValues({
        'food_items': jsonEncode([
          {
            'id': 'a',
            'name': 'Apple',
            'carbs': 25.0,
            'loggedAt': '2026-03-09T10:00:00.000',
            'category': 'snack'
          },
          {
            'id': 'b',
            'name': 'Bagel',
            'carbs': 48.0,
            'loggedAt': '2026-03-09T09:00:00.000',
            'category': 'breakfast'
          },
          {
            'id': 'c',
            'name': 'Cereal',
            'carbs': 30.0,
            'loggedAt': '2026-03-09T08:00:00.000',
            'category': 'breakfast'
          },
        ]),
        'last_save_date': todayKey(),
      });
    }

    Map<String, Object?> cloudPayloadDeleting(List<String> ids) => {
          'food_items': jsonEncode([
            {
              'id': 'a',
              'name': 'Apple',
              'carbs': 25.0,
              'loggedAt': '2026-03-09T10:00:00.000',
              'category': 'snack'
            },
            {
              'id': 'b',
              'name': 'Bagel',
              'carbs': 48.0,
              'loggedAt': '2026-03-09T09:00:00.000',
              'category': 'breakfast'
            },
            {
              'id': 'c',
              'name': 'Cereal',
              'carbs': 30.0,
              'loggedAt': '2026-03-09T08:00:00.000',
              'category': 'breakfast'
            },
          ]),
          'food_items_deleted': jsonEncode(ids),
          'last_save_date': todayKey(),
          'cloud_last_modified': DateTime.now().toIso8601String(),
        };

    /// Answers pulls with [payload]; pushes report failure, which the app
    /// shows as a failed sync and is not what these tests are about.
    void stubCloudSyncReturning(Map<String, Object?>? payload) {
      const channel = MethodChannel('com.carpecarb/cloudsync');
      messenger().setMockMethodCallHandler(channel,
          (call) async => call.method == 'pullFromCloud' ? payload : false);
      addTearDown(() => messenger().setMockMethodCallHandler(channel, null));
    }

    /// Delivers a remote change the way the native observer does, so the app
    /// merges it while the list is on screen.
    Future<void> sendRemoteChange(
        WidgetTester tester, Map<String, Object?> payload) async {
      await messenger().handlePlatformMessage(
        'com.carpecarb/cloudsync',
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('onRemoteChange', payload)),
        (_) {},
      );
      // The service debounces remote changes by 300ms.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'a remote delete shortens the list on screen without a range error',
        (WidgetTester tester) async {
      stubHomeWidget();
      seedThreeItemsToday();
      // Nothing in the cloud at launch, so all three items render first —
      // which is what leaves the AnimatedList counting them.
      stubCloudSyncReturning(null);

      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );
      expect(state.foodItems, hasLength(3));
      expect(find.text('Bagel'), findsOneWidget);

      await sendRemoteChange(tester, cloudPayloadDeleting(['b', 'c']));

      expect(state.foodItems.map((f) => f.name), ['Apple']);
      expect(find.text('Bagel'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a remote delete survives the next merge',
        (WidgetTester tester) async {
      stubHomeWidget();
      seedThreeItemsToday();
      stubCloudSyncReturning(cloudPayloadDeleting(['b', 'c']));

      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();

      final state = tester.state<CarbTrackerHomeState>(
        find.byType(CarbTrackerHome),
      );
      expect(state.foodItems, hasLength(1));

      // A second pull of the same payload — the deleted items are still gone
      // rather than merging back in.
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(state.foodItems.map((f) => f.name), ['Apple']);
      expect(tester.takeException(), isNull);
    });
  });
}
```


- [ ] **Step 2: Run them and watch them fail**

Run: `flutter test test/widget_test.dart`
Expected: both new tests fail. The first (`a remote delete shortens the list on screen without a range error`) is the interesting one: without the fix it reports
`RangeError (length): Invalid value: Only valid value is 0: 1` — the AnimatedList still counting three items while the list holds one.

- [ ] **Step 3: Read the native push result**

In `lib/services/cloud_sync_service.dart`:

**Edit 1 of 1 — replace:**

```dart
      dev.log('CloudSyncService.isAvailable error: $e');
      return false;
    }
  }

  /// Push [data] to iCloud. Returns true if the push succeeded.
  Future<bool> pushToCloud(Map<String, dynamic> data) async {
    try {
      await _channel.invokeMethod('pushToCloud', data);
      return true;
    } catch (e) {
      dev.log('CloudSyncService.pushToCloud error: $e');
      return false;
    }
  }
```

**with:**

```dart
      dev.log('CloudSyncService.isAvailable error: $e');
      return false;
    }
  }

  /// Push [data] to iCloud. Returns true if the push succeeded.
  ///
  /// The native side answers false when iCloud is signed out or the write
  /// didn't go through (CloudSyncChannel.swift), so its answer is what decides
  /// here — reporting success regardless is what made the app show the synced
  /// icon after a push that did nothing.
  Future<bool> pushToCloud(Map<String, dynamic> data) async {
    try {
      final pushed = await _channel.invokeMethod<bool>('pushToCloud', data);
      return pushed ?? false;
    } catch (e) {
      dev.log('CloudSyncService.pushToCloud error: $e');
      return false;
    }
  }
```


- [ ] **Step 4: Wire the merge into the app**

In `lib/main.dart` — ten edits, in order:

**Edit 1 of 10 — replace:**

```dart
import 'dart:io';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_import.dart';
import 'models/food_item.dart';
import 'models/server_quota.dart';
import 'screens/settings_page.dart';
import 'config/app_colors.dart';
import 'config/app_theme.dart';
import 'config/storage_keys.dart';
```

**with:**

```dart
import 'dart:io';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_import.dart';
import 'services/sync_merge.dart';
import 'services/sync_payload.dart';
import 'services/sync_store.dart';
import 'models/food_item.dart';
import 'models/server_quota.dart';
import 'screens/settings_page.dart';
import 'config/app_colors.dart';
import 'config/app_theme.dart';
import 'config/storage_keys.dart';
```

**Edit 2 of 10 — replace:**

```dart
class CarbTrackerHomeState extends State<CarbTrackerHome>
    with WidgetsBindingObserver {
  final TextEditingController _foodController = TextEditingController();
  final TextEditingController _carbController = TextEditingController();
  final FocusNode _foodFocusNode = FocusNode();
  final FocusNode _carbFocusNode = FocusNode();
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final PerplexityFirebaseService _perplexityService =
      PerplexityFirebaseService();
  final HealthKitService _healthKitService = HealthKitService();
  final PremiumService _premiumService = PremiumService();
  final CloudSyncService _cloudSyncService = CloudSyncService();
  bool _isManualEntryMode = false;

  List<FoodItem> foodItems = [];
  double get totalCarbs => foodItems.fold(0.0, (sum, item) => sum + item.carbs);
  bool isLoading = false;
  bool showingDailyTotal = false;
```

**with:**

```dart
class CarbTrackerHomeState extends State<CarbTrackerHome>
    with WidgetsBindingObserver {
  final TextEditingController _foodController = TextEditingController();
  final TextEditingController _carbController = TextEditingController();
  final FocusNode _foodFocusNode = FocusNode();
  final FocusNode _carbFocusNode = FocusNode();
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final PerplexityFirebaseService _perplexityService =
      PerplexityFirebaseService();
  final HealthKitService _healthKitService = HealthKitService();
  final PremiumService _premiumService = PremiumService();
  final CloudSyncService _cloudSyncService = CloudSyncService();
  final SyncStore _syncStore = SyncStore();
  bool _isManualEntryMode = false;

  List<FoodItem> foodItems = [];
  double get totalCarbs => foodItems.fold(0.0, (sum, item) => sum + item.carbs);
  bool isLoading = false;
  bool showingDailyTotal = false;
```

**Edit 3 of 10 — replace:**

```dart
    if (mounted) _foodFocusNode.requestFocus();
  }

  Future<void> _initCloudSync() async {
    await _cloudSyncService.startListening(_onRemoteCloudChange);
    final pulled = await _cloudSyncService.pullFromCloud();
    if (pulled != null && mounted) {
      final prefs = await SharedPreferences.getInstance();
      final cloudTs = pulled[StorageKeys.cloudLastModified] as String? ?? '';
      final localTs = prefs.getString(StorageKeys.cloudLastModified) ?? '';
      final cloudDt = DateTime.tryParse(cloudTs);
      final localDt = DateTime.tryParse(localTs);
      if (cloudDt != null && (localDt == null || cloudDt.isAfter(localDt))) {
        await _applyCloudData(pulled);
      }
    }
  }

  void _onRemoteCloudChange(Map<String, dynamic>? data) {
    if (data != null && mounted) _applyCloudData(data);
  }

  /// Builds the payload of all syncable data for a cloud push.
  /// [timestamp] is written as [StorageKeys.cloudLastModified] so the caller
  /// can save it locally after a successful push.
  Map<String, dynamic> _buildSyncPayload(SharedPreferences prefs,
      {String? timestamp}) {
    return {
      StorageKeys.foodItems:
          jsonEncode(foodItems.map((f) => f.toJson()).toList()),
      StorageKeys.savedFoods: prefs.getString(StorageKeys.savedFoods) ?? '',
      StorageKeys.dailyCarbGoal: dailyCarbGoal ?? 0.0,
      StorageKeys.dailyResetHour: resetHour,
      StorageKeys.lastSaveDate: _todayString(),
      StorageKeys.proteinGoal: proteinGoal ?? 0.0,
      StorageKeys.fatGoal: fatGoal ?? 0.0,
      StorageKeys.fiberGoal: fiberGoal ?? 0.0,
      StorageKeys.caloriesGoal: caloriesGoal ?? 0.0,
      StorageKeys.cloudLastModified:
          timestamp ?? DateTime.now().toIso8601String(),
    };
  }

  /// Parses a JSON string into a list of FoodItems, returning [] on any error.
  List<FoodItem> _parseFoodItemJson(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final decoded = jsonDecode(json) as List<dynamic>;
      return decoded
          .map((e) => FoodItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Applies a cloud data payload to SharedPreferences then reloads state.
  /// Food items and favorites are merged with local data (not replaced) so that
  /// neither device loses its own data when syncing.
  Future<void> _applyCloudData(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();

    // ── Goals: await each write so _loadSavedData reads current values ──
    Future<void> applyGoal(String key, dynamic val) async {
      if (val is num && val.toDouble() > 0) {
        await prefs.setDouble(key, val.toDouble());
      } else if (val is num) {
        await prefs.remove(key);
      }
    }

    await Future.wait([
      applyGoal(StorageKeys.dailyCarbGoal, data[StorageKeys.dailyCarbGoal]),
      applyGoal(StorageKeys.proteinGoal, data[StorageKeys.proteinGoal]),
      applyGoal(StorageKeys.fatGoal, data[StorageKeys.fatGoal]),
      applyGoal(StorageKeys.fiberGoal, data[StorageKeys.fiberGoal]),
      applyGoal(StorageKeys.caloriesGoal, data[StorageKeys.caloriesGoal]),
    ]);

    final resetHourVal = data[StorageKeys.dailyResetHour];
    if (resetHourVal is num) {
      await prefs.setInt(StorageKeys.dailyResetHour, resetHourVal.toInt());
    }

    // ── Favorites: merge by name so neither device loses saved foods ──
    if (data[StorageKeys.savedFoods] is String) {
      final localFavs =
          _parseFoodItemJson(prefs.getString(StorageKeys.savedFoods));
      final cloudFavs =
          _parseFoodItemJson(data[StorageKeys.savedFoods] as String);
      final seen = <String>{};
      final mergedFavs = <FoodItem>[];
      for (final item in [...cloudFavs, ...localFavs]) {
        if (seen.add(item.name.toLowerCase())) mergedFavs.add(item);
      }
      await prefs.setString(StorageKeys.savedFoods,
          jsonEncode(mergedFavs.map((f) => f.toJson()).toList()));
    }

    // ── Food items: merge by loggedAt so both devices' logs are preserved ──
    bool pushedMergedList = false;
    final cloudSaveDate = data[StorageKeys.lastSaveDate] is String
        ? data[StorageKeys.lastSaveDate] as String
        : null;
    final today = _todayString();
    if (cloudSaveDate == today && data[StorageKeys.foodItems] is String) {
      final localItems =
          _parseFoodItemJson(prefs.getString(StorageKeys.foodItems));
      final cloudItems =
          _parseFoodItemJson(data[StorageKeys.foodItems] as String);

      // Combine, dedup by stable item ID, sort newest-first.
      // Cloud items take priority so the remote version wins on ID collision.
      final seen = <String>{};
      final merged = <FoodItem>[];
      for (final item in [...cloudItems, ...localItems]) {
        if (seen.add(item.id)) merged.add(item);
      }
      merged.sort((a, b) => b.loggedAt.compareTo(a.loggedAt));

      final mergedJson = jsonEncode(merged.map((f) => f.toJson()).toList());
      await prefs.setString(StorageKeys.foodItems, mergedJson);
      await prefs.setString(StorageKeys.lastSaveDate, today);

      // If we contributed local items the cloud didn't have, push the merged
      // list back so the other device also receives them.
      if (merged.length > cloudItems.length &&
          _premiumService.isCloudSyncEnabled) {
        final newTs = DateTime.now().toIso8601String();
        // Build push from current local state (not incoming data) so we don't
        // propagate stale goal/settings values that may have changed locally.
        final pushed = await _pushToCloud({
          ..._buildSyncPayload(prefs),
          StorageKeys.foodItems: mergedJson,
          StorageKeys.cloudLastModified: newTs,
        });
        // Only advance the local timestamp if the push succeeded. If it failed,
        // keep the old timestamp so we retry on next sync.
        if (pushed) {
          await prefs.setString(StorageKeys.cloudLastModified, newTs);
          pushedMergedList = true;
        }
      }
    }

    if (!pushedMergedList && data[StorageKeys.cloudLastModified] is String) {
      await prefs.setString(StorageKeys.cloudLastModified,
          data[StorageKeys.cloudLastModified] as String);
    }

    if (mounted) await _loadSavedData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
```

**with:**

```dart
    if (mounted) _foodFocusNode.requestFocus();
  }

  Future<void> _initCloudSync() async {
    await _cloudSyncService.startListening(_onRemoteCloudChange);
    final pulled = await _cloudSyncService.pullFromCloud();
    // Merged unconditionally: merging is safe to repeat, and the timestamp
    // gate this replaced skipped remote changes whenever this device had
    // pushed more recently than the change it was ignoring.
    if (pulled != null && mounted) await _applyCloudData(pulled);
  }

  void _onRemoteCloudChange(Map<String, dynamic>? data) {
    if (data != null && mounted) _applyCloudData(data);
  }

  /// Pushes this device's state to iCloud: today's items and what was deleted
  /// today, the favourites and when each last changed, and the settings with
  /// the time they were last changed here. The other device needs all of it to
  /// merge instead of resurrecting what this one deleted.
  ///
  /// Call after the local change has been written to SharedPreferences —
  /// the payload is built from what is stored, not from in-memory state.
  Future<void> _pushLocalState() async {
    if (!_premiumService.isCloudSyncEnabled) return;
    final prefs = await SharedPreferences.getInstance();
    final state = await _syncStore.read(_todayString());
    final timestamp = DateTime.now();
    final pushed =
        await _pushToCloud(encodeSyncPayload(state, timestamp: timestamp));
    // Only advance the local timestamp when the push really landed, so a push
    // that failed (iCloud signed out) is retried on the next change.
    if (pushed) {
      await prefs.setString(
          StorageKeys.cloudLastModified, timestamp.toIso8601String());
    }
  }

  /// Merges a cloud payload into local data, then reloads the UI.
  ///
  /// The merge keeps both devices' items and favourites, honours deletes from
  /// either side, and takes the newer settings — see
  /// `lib/services/sync_merge.dart`. Launch, resume and a live remote change
  /// all come through here.
  Future<void> _applyCloudData(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final cloud = decodeSyncPayload(data);
    final local = await _syncStore.read(_todayString());
    final merged =
        mergeSyncState(local: local, cloud: cloud, now: DateTime.now());
    await _syncStore.write(merged);

    if (data[StorageKeys.cloudLastModified] is String) {
      await prefs.setString(StorageKeys.cloudLastModified,
          data[StorageKeys.cloudLastModified] as String);
    }

    if (mounted) await _loadSavedData();

    // Push back only what the cloud is missing. When both sides already agree
    // the merge changes nothing, neither device pushes, and the pair settles
    // instead of answering each other's pushes forever.
    if (syncStateDiffers(merged, cloud)) await _pushLocalState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
```

**Edit 4 of 10 — replace:**

```dart
    fiberGoal = prefs.getDouble(StorageKeys.fiberGoal);
    caloriesGoal = prefs.getDouble(StorageKeys.caloriesGoal);
    final lastSaveDate = prefs.getString(StorageKeys.lastSaveDate);
    final isNewDay = lastSaveDate != null && lastSaveDate != _todayString();

    if (isNewDay) {
      // New day — reset everything
      await prefs.remove(StorageKeys.foodItems);
      await prefs.remove(StorageKeys.lastSaveDate);
      await prefs.setDouble(StorageKeys.totalCarbs, 0.0);
      await HomeWidget.saveWidgetData<double>(
          StorageKeys.widgetTotalCarbs, 0.0);
      await HomeWidget.saveWidgetData<String>(
          StorageKeys.widgetLastFoodName, '');
```

**with:**

```dart
    fiberGoal = prefs.getDouble(StorageKeys.fiberGoal);
    caloriesGoal = prefs.getDouble(StorageKeys.caloriesGoal);
    final lastSaveDate = prefs.getString(StorageKeys.lastSaveDate);
    final isNewDay = lastSaveDate != null && lastSaveDate != _todayString();

    if (isNewDay) {
      // New day — reset everything. The delete markers go with the items
      // they belong to; yesterday's cloud payload is ignored by the merge.
      await _syncStore.clearDay();
      await prefs.remove(StorageKeys.lastSaveDate);
      await prefs.setDouble(StorageKeys.totalCarbs, 0.0);
      await HomeWidget.saveWidgetData<double>(
          StorageKeys.widgetTotalCarbs, 0.0);
      await HomeWidget.saveWidgetData<String>(
          StorageKeys.widgetLastFoodName, '');
```

**Edit 5 of 10 — replace:**

```dart
    }

    if (!mounted || token != _loadSavedDataToken) return;
    setState(() {
      foodItems = loadedItems;
      dailyCarbGoal = savedGoal;
    });

    // Pick up any food items logged via Siri while the app was closed
    await _importSiriLoggedItems();
  }
```

**with:**

```dart
    }

    if (!mounted || token != _loadSavedDataToken) return;
    setState(() {
      foodItems = loadedItems;
      dailyCarbGoal = savedGoal;
      // The list is replaced wholesale, so give the AnimatedList a new key:
      // its state still counts the items it had, and a merge that leaves
      // fewer would make it build rows that no longer exist (RangeError).
      _listKey = GlobalKey<AnimatedListState>();
    });

    // Pick up any food items logged via Siri while the app was closed
    await _importSiriLoggedItems();
  }
```

**Edit 6 of 10 — replace:**

```dart
      await prefs.remove(StorageKeys.dailyCarbGoal);
    }
    final itemsJson = jsonEncode(foodItems.map((f) => f.toJson()).toList());
    await prefs.setString(StorageKeys.foodItems, itemsJson);
    await prefs.setString(StorageKeys.lastSaveDate, _todayString());

    // Push to iCloud if cloud sync is enabled
    if (_premiumService.isCloudSyncEnabled) {
      final ts = DateTime.now().toIso8601String();
      final pushed = await _pushToCloud(_buildSyncPayload(prefs, timestamp: ts));
      if (pushed) await prefs.setString(StorageKeys.cloudLastModified, ts);
    }
  }

  String _todayString() => dayKey(DateTime.now(), resetHour);

  String? _validateFoodInput(String input) {
    // Use hardened validation from InputValidation utility
```

**with:**

```dart
      await prefs.remove(StorageKeys.dailyCarbGoal);
    }
    final itemsJson = jsonEncode(foodItems.map((f) => f.toJson()).toList());
    await prefs.setString(StorageKeys.foodItems, itemsJson);
    await prefs.setString(StorageKeys.lastSaveDate, _todayString());

    await _pushLocalState();
  }

  String _todayString() => dayKey(DateTime.now(), resetHour);

  String? _validateFoodInput(String input) {
    // Use hardened validation from InputValidation utility
```

**Edit 7 of 10 — replace:**

```dart
    // Delete all reset items from HealthKit
    if (_premiumService.isHealthSyncEnabled) {
      for (final item in snapshot) {
        _deleteFromHealthKit(item);
      }
    }
    _saveData();
    _updateWidget();
  }

  void removeItem(int index) {
    final removedItem = foodItems[index];
    setState(() {
      foodItems.removeAt(index);
    });
    _listKey.currentState?.removeItem(
      index,
      (context, animation) => _buildAnimatedItem(removedItem, animation),
      duration: const Duration(milliseconds: 300),
    );
    _saveData();
    _updateWidget();
    if (_premiumService.isHealthSyncEnabled) {
      _deleteFromHealthKit(removedItem);
    }

    if (mounted) {
```

**with:**

```dart
    // Delete all reset items from HealthKit
    if (_premiumService.isHealthSyncEnabled) {
      for (final item in snapshot) {
        _deleteFromHealthKit(item);
      }
    }
    _saveAfterDeleting(snapshot.map((item) => item.id).toList());
    _updateWidget();
  }

  /// Records [ids] as deleted today, then saves and pushes. The marker has to
  /// be written before the push so the payload carries it; without it the
  /// other device's copy of the item merges straight back in.
  Future<void> _saveAfterDeleting(List<String> ids) async {
    await _syncStore.recordItemsDeleted(ids);
    await _saveData();
  }

  /// Undo: the item is wanted again, so its delete marker goes.
  Future<void> _saveAfterRestoring(String id) async {
    await _syncStore.recordItemRestored(id);
    await _saveData();
  }

  void removeItem(int index) {
    final removedItem = foodItems[index];
    setState(() {
      foodItems.removeAt(index);
    });
    _listKey.currentState?.removeItem(
      index,
      (context, animation) => _buildAnimatedItem(removedItem, animation),
      duration: const Duration(milliseconds: 300),
    );
    _saveAfterDeleting([removedItem.id]);
    _updateWidget();
    if (_premiumService.isHealthSyncEnabled) {
      _deleteFromHealthKit(removedItem);
    }

    if (mounted) {
```

**Edit 8 of 10 — replace:**

```dart
                foodItems.insert(index.clamp(0, foodItems.length), removedItem);
              });
              _listKey.currentState?.insertItem(
                index.clamp(0, foodItems.length - 1),
                duration: const Duration(milliseconds: 400),
              );
              _saveData();
              _updateWidget();
              if (_premiumService.isHealthSyncEnabled) {
                _writeToHealthKit(removedItem);
              }
            },
          ),
```

**with:**

```dart
                foodItems.insert(index.clamp(0, foodItems.length), removedItem);
              });
              _listKey.currentState?.insertItem(
                index.clamp(0, foodItems.length - 1),
                duration: const Duration(milliseconds: 400),
              );
              _saveAfterRestoring(removedItem.id);
              _updateWidget();
              if (_premiumService.isHealthSyncEnabled) {
                _writeToHealthKit(removedItem);
              }
            },
          ),
```

**Edit 9 of 10 — replace:**

```dart
      fatGoal = result.fatGoal;
      fiberGoal = result.fiberGoal;
      caloriesGoal = result.caloriesGoal;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.dailyResetHour, resetHour);
    await _saveData();
    await _updateWidget();
  }

  /// Called by SettingsPage when favorites are added/removed, so we can push
  /// the full sync payload (which includes saved_foods) to iCloud.
  Future<void> _onFavoritesChanged() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = DateTime.now().toIso8601String();
    final pushed = await _pushToCloud(_buildSyncPayload(prefs, timestamp: ts));
    if (pushed) await prefs.setString(StorageKeys.cloudLastModified, ts);
  }

  Widget _buildFoodTile(FoodItem item) {
    return FoodItemCard(
      name: item.name,
      subtitle: formatTime(item.loggedAt),
      carbs: item.carbs,
```

**with:**

```dart
      fatGoal = result.fatGoal;
      fiberGoal = result.fiberGoal;
      caloriesGoal = result.caloriesGoal;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.dailyResetHour, resetHour);
    // Stamp the change so these settings win over an older device's.
    await _syncStore.markSettingsChanged();
    await _saveData();
    await _updateWidget();
  }

  /// Called by SettingsPage after it has written the favourites and recorded
  /// the change, so the new list reaches the other device.
  Future<void> _onFavoritesChanged() => _pushLocalState();

  Widget _buildFoodTile(FoodItem item) {
    return FoodItemCard(
      name: item.name,
      subtitle: formatTime(item.loggedAt),
      carbs: item.carbs,
```

**Edit 10 of 10 — replace:**

```dart
    if (!exists) {
      savedFoods.add(item);
      final encoded = jsonEncode(savedFoods.map((f) => f.toJson()).toList());
      await prefs.setString(StorageKeys.savedFoods, encoded);
      setState(() => _favoritesVersion++);

      if (_premiumService.isCloudSyncEnabled) {
        final ts = DateTime.now().toIso8601String();
        final pushed = await _pushToCloud(_buildSyncPayload(prefs, timestamp: ts));
        if (pushed) await prefs.setString(StorageKeys.cloudLastModified, ts);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${item.name} saved to Food list'),
            duration: const Duration(seconds: 2),
```

**with:**

```dart
    if (!exists) {
      savedFoods.add(item);
      final encoded = jsonEncode(savedFoods.map((f) => f.toJson()).toList());
      await prefs.setString(StorageKeys.savedFoods, encoded);
      setState(() => _favoritesVersion++);

      await _syncStore.recordFavoriteAdded(item.name);
      await _pushLocalState();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${item.name} saved to Food list'),
            duration: const Duration(seconds: 2),
```


- [ ] **Step 5: Record favourite deletes**

In `lib/screens/settings_page.dart`:

**Edit 1 of 5 — replace:**

```dart
import '../config/storage_keys.dart';
import '../models/food_item.dart';
import '../services/health_kit_service.dart';
import '../services/premium_service.dart';
import '../services/purchase_service.dart';
import '../services/cloud_sync_service.dart';
import '../utils/date_format.dart';
import '../widgets/food_item_card.dart';

class SettingsResult {
  final double? dailyCarbGoal;
  final int resetHour;
```

**with:**

```dart
import '../config/storage_keys.dart';
import '../models/food_item.dart';
import '../services/health_kit_service.dart';
import '../services/premium_service.dart';
import '../services/purchase_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/sync_store.dart';
import '../utils/date_format.dart';
import '../widgets/food_item_card.dart';

class SettingsResult {
  final double? dailyCarbGoal;
  final int resetHour;
```

**Edit 2 of 5 — replace:**

```dart
  final FocusNode _fatGoalFocusNode = FocusNode();
  final FocusNode _fiberGoalFocusNode = FocusNode();
  final FocusNode _caloriesGoalFocusNode = FocusNode();

  // Favorites state
  List<FoodItem> _savedFoods = [];
  bool _isFavoritesLoading = true;

  // History state
  Map<DateTime, List<Map<String, dynamic>>> _dailyHistory = {};
  bool _isHistoryLoading = true;
  bool _hasPermission = true;
```

**with:**

```dart
  final FocusNode _fatGoalFocusNode = FocusNode();
  final FocusNode _fiberGoalFocusNode = FocusNode();
  final FocusNode _caloriesGoalFocusNode = FocusNode();

  // Favorites state
  List<FoodItem> _savedFoods = [];
  final SyncStore _syncStore = SyncStore();
  bool _isFavoritesLoading = true;

  // History state
  Map<DateTime, List<Map<String, dynamic>>> _dailyHistory = {};
  bool _isHistoryLoading = true;
  bool _hasPermission = true;
```

**Edit 3 of 5 — replace:**

```dart
        ],
      ),
    );
    if (confirmed == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(StorageKeys.savedFoods);
      setState(() => _savedFoods.clear());
      widget.onFavoritesChanged?.call();
    }
  }

  Future<void> _removeSavedFood(int index) async {
```

**with:**

```dart
        ],
      ),
    );
    if (confirmed == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(StorageKeys.savedFoods);
      // Record each one as deleted, or the other device's copies merge back in.
      await _syncStore.recordFavoritesCleared(_savedFoods);
      setState(() => _savedFoods.clear());
      widget.onFavoritesChanged?.call();
    }
  }

  Future<void> _removeSavedFood(int index) async {
```

**Edit 4 of 5 — replace:**

```dart
    setState(() => _savedFoods.removeAt(index));
    HapticFeedback.mediumImpact();

    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_savedFoods.map((f) => f.toJson()).toList());
    await prefs.setString(StorageKeys.savedFoods, encoded);
    widget.onFavoritesChanged?.call();

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
```

**with:**

```dart
    setState(() => _savedFoods.removeAt(index));
    HapticFeedback.mediumImpact();

    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_savedFoods.map((f) => f.toJson()).toList());
    await prefs.setString(StorageKeys.savedFoods, encoded);
    await _syncStore.recordFavoriteRemoved(removed.name);
    widget.onFavoritesChanged?.call();

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
```

**Edit 5 of 5 — replace:**

```dart
          onPressed: () async {
            setState(() {
              _savedFoods.insert(
                  index.clamp(0, _savedFoods.length), removed);
            });
            final p = await SharedPreferences.getInstance();
            await p.setString(
                StorageKeys.savedFoods,
                jsonEncode(
                    _savedFoods.map((f) => f.toJson()).toList()));
            widget.onFavoritesChanged?.call();
          },
        ),
      ),
    );
  }
```

**with:**

```dart
          onPressed: () async {
            setState(() {
              _savedFoods.insert(
                  index.clamp(0, _savedFoods.length), removed);
            });
            final p = await SharedPreferences.getInstance();
            await p.setString(StorageKeys.savedFoods,
                jsonEncode(_savedFoods.map((f) => f.toJson()).toList()));
            await _syncStore.recordFavoriteAdded(removed.name);
            widget.onFavoritesChanged?.call();
          },
        ),
      ),
    );
  }
```


- [ ] **Step 6: Run the tests**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` and `+121: All tests passed!`

- [ ] **Step 7: Commit**

```bash
git add lib/main.dart lib/screens/settings_page.dart lib/services/cloud_sync_service.dart test/widget_test.dart
git commit -m "fix(sync): merge cloud data instead of overwriting it"
```

---

### Task 6: App wiring — take the Siri buffer

Swap the two-call read-then-clear for Task 4's channel.

**Files:**
- Create: `lib/services/siri_buffer_service.dart`
- Modify: `lib/main.dart`
- Test: `test/widget_test.dart`

**Interfaces:**
- Consumes: Task 4's `com.carpecarb/siribuffer` / `takeLoggedItems`.
- Produces: `SiriBufferService.takeLoggedItems() → Future<String?>`.

- [ ] **Step 1: Write the failing test**

In `test/widget_test.dart` — three edits: a stub with the channel's take-and-clear contract, and the existing Siri test switched over to it:

**Edit 1 of 3 — replace:**

```dart
      return null;
    });
    addTearDown(() => messenger().setMockMethodCallHandler(channel, null));
    return appGroup;
  }

  /// Makes iCloud pulls return an empty payload, so a resume runs
  /// `_applyCloudData` (and its `_loadSavedData`) alongside the resume's own.
  void stubCloudSync() {
    const channel = MethodChannel('com.carpecarb/cloudsync');
    messenger().setMockMethodCallHandler(channel,
        (call) async => call.method == 'pullFromCloud' ? <String, Object?>{} : null);
```

**with:**

```dart
      return null;
    });
    addTearDown(() => messenger().setMockMethodCallHandler(channel, null));
    return appGroup;
  }

  /// Stands in for `SiriBufferChannel`: hands over the buffer once and
  /// empties it, the way the native side does. Returns the buffer so a test
  /// can put items in it.
  List<Map<String, Object?>> stubSiriBuffer() {
    const channel = MethodChannel('com.carpecarb/siribuffer');
    final buffer = <Map<String, Object?>>[];
    messenger().setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'takeLoggedItems') return null;
      if (buffer.isEmpty) return null;
      final taken = jsonEncode(buffer);
      buffer.clear();
      return taken;
    });
    addTearDown(() => messenger().setMockMethodCallHandler(channel, null));
    return buffer;
  }

  /// Makes iCloud pulls return an empty payload, so a resume runs
  /// `_applyCloudData` (and its `_loadSavedData`) alongside the resume's own.
  void stubCloudSync() {
    const channel = MethodChannel('com.carpecarb/cloudsync');
    messenger().setMockMethodCallHandler(channel,
        (call) async => call.method == 'pullFromCloud' ? <String, Object?>{} : null);
```

**Edit 2 of 3 — replace:**

```dart
      expect(state.foodItems, isEmpty);
    });

    testWidgets(
        'resume after the day changed, with iCloud sync, imports Siri items into the new day',
        (WidgetTester tester) async {
      final appGroup = stubHomeWidget();
      stubCloudSync();

      SharedPreferences.setMockInitialValues({
        'food_items':
            '[{"name":"Pasta","carbs":60.0,"loggedAt":"2026-03-09T19:00:00.000","category":"dinner"},'
                '{"name":"Apple","carbs":25.0,"loggedAt":"2026-03-09T10:00:00.000","category":"snack"}]',
```

**with:**

```dart
      expect(state.foodItems, isEmpty);
    });

    testWidgets(
        'resume after the day changed, with iCloud sync, imports Siri items into the new day',
        (WidgetTester tester) async {
      stubHomeWidget();
      final siriBuffer = stubSiriBuffer();
      stubCloudSync();

      SharedPreferences.setMockInitialValues({
        'food_items':
            '[{"name":"Pasta","carbs":60.0,"loggedAt":"2026-03-09T19:00:00.000","category":"dinner"},'
                '{"name":"Apple","carbs":25.0,"loggedAt":"2026-03-09T10:00:00.000","category":"snack"}]',
```

**Edit 3 of 3 — replace:**

```dart
      );
      expect(state.foodItems, hasLength(2));

      // Overnight the saved list becomes yesterday's, and Siri logs a food.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_save_date', yesterdayKey());
      appGroup['siriLoggedItems'] = jsonEncode([
        {
          'name': 'Toast',
          'carbs': 15,
          'loggedAt': DateTime.now().toUtc().toIso8601String(),
        },
      ]);

      // Resume starts both the day reload and an iCloud pull, whose
      // _applyCloudData reloads again while the first reload is in flight.
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
```

**with:**

```dart
      );
      expect(state.foodItems, hasLength(2));

      // Overnight the saved list becomes yesterday's, and Siri logs a food.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_save_date', yesterdayKey());
      siriBuffer.add({
        'name': 'Toast',
        'carbs': 15,
        'loggedAt': DateTime.now().toUtc().toIso8601String(),
      });

      // Resume starts both the day reload and an iCloud pull, whose
      // _applyCloudData reloads again while the first reload is in flight.
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
```


- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/widget_test.dart`
Expected: `resume after the day changed, with iCloud sync, imports Siri items into the new day` fails with
`Expected: ['Toast'] Actual: MappedListIterable<FoodItem, String>:[]` — the app is still reading the buffer through `home_widget`, which the test no longer seeds.

- [ ] **Step 3: Add the service**

Create `lib/services/siri_buffer_service.dart`:

```dart
import 'dart:developer' as dev;

import 'package:flutter/services.dart';

/// Takes the food Siri logged while the app was away.
///
/// The native side (`ios/Runner/SiriBufferChannel.swift`) hands over the buffer
/// and clears it in one step, so a Siri log that arrives while the app is
/// importing isn't overwritten — reading and clearing in two calls used to
/// drop it.
class SiriBufferService {
  static const _channel = MethodChannel('com.carpecarb/siribuffer');

  /// Returns the buffered items as JSON and empties the buffer, or null when
  /// nothing is waiting (or the channel isn't there, as on Android).
  Future<String?> takeLoggedItems() async {
    try {
      return await _channel.invokeMethod<String>('takeLoggedItems');
    } catch (e) {
      dev.log('SiriBufferService.takeLoggedItems error: $e');
      return null;
    }
  }
}
```

- [ ] **Step 4: Use it**

In `lib/main.dart` — four edits:

**Edit 1 of 4 — replace:**

```dart
import 'dart:convert';
import 'dart:io';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_import.dart';
import 'services/sync_merge.dart';
import 'services/sync_payload.dart';
import 'services/sync_store.dart';
import 'models/food_item.dart';
import 'models/server_quota.dart';
```

**with:**

```dart
import 'dart:convert';
import 'dart:io';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_buffer_service.dart';
import 'services/siri_import.dart';
import 'services/sync_merge.dart';
import 'services/sync_payload.dart';
import 'services/sync_store.dart';
import 'models/food_item.dart';
import 'models/server_quota.dart';
```

**Edit 2 of 4 — replace:**

```dart
  final PerplexityFirebaseService _perplexityService =
      PerplexityFirebaseService();
  final HealthKitService _healthKitService = HealthKitService();
  final PremiumService _premiumService = PremiumService();
  final CloudSyncService _cloudSyncService = CloudSyncService();
  final SyncStore _syncStore = SyncStore();
  bool _isManualEntryMode = false;

  List<FoodItem> foodItems = [];
  double get totalCarbs => foodItems.fold(0.0, (sum, item) => sum + item.carbs);
  bool isLoading = false;
  bool showingDailyTotal = false;
```

**with:**

```dart
  final PerplexityFirebaseService _perplexityService =
      PerplexityFirebaseService();
  final HealthKitService _healthKitService = HealthKitService();
  final PremiumService _premiumService = PremiumService();
  final CloudSyncService _cloudSyncService = CloudSyncService();
  final SyncStore _syncStore = SyncStore();
  final SiriBufferService _siriBuffer = SiriBufferService();
  bool _isManualEntryMode = false;

  List<FoodItem> foodItems = [];
  double get totalCarbs => foodItems.fold(0.0, (sum, item) => sum + item.carbs);
  bool isLoading = false;
  bool showingDailyTotal = false;
```

**Edit 3 of 4 — replace:**

```dart
    final token = ++_importSiriItemsToken;
    // Let a just-replaced list rebuild first (a new day, or a reload that
    // swapped in fewer items), so the inserts below don't hit the old
    // AnimatedList, which still counts the previous items.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || token != _importSiriItemsToken) return;
    final siriItemsJson = await HomeWidget.getWidgetData<String>(
        StorageKeys.widgetSiriLoggedItems);
    if (!mounted || token != _importSiriItemsToken) return;
    if (siriItemsJson == null) return;

    try {
      final siri =
          SiriImport.parse(siriItemsJson, DateTime.now(), resetHour);
```

**with:**

```dart
    final token = ++_importSiriItemsToken;
    // Let a just-replaced list rebuild first (a new day, or a reload that
    // swapped in fewer items), so the inserts below don't hit the old
    // AnimatedList, which still counts the previous items.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || token != _importSiriItemsToken) return;
    // Taken and cleared in one native step: a Siri log that lands while this
    // runs is kept for the next import instead of being overwritten.
    final siriItemsJson = await _siriBuffer.takeLoggedItems();
    if (!mounted || token != _importSiriItemsToken) return;
    if (siriItemsJson == null) return;

    try {
      final siri =
          SiriImport.parse(siriItemsJson, DateTime.now(), resetHour);
```

**Edit 4 of 4 — replace:**

```dart
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
```

**with:**

```dart
          foodItems.insert(0, foodItem);
        });
        _listKey.currentState
            ?.insertItem(0, duration: const Duration(milliseconds: 400));
      }

      await _saveData();
      await _updateWidget();

      // Items from an earlier day stay out of today's list but still go to
      // Apple Health at the time they were logged.
      if (_premiumService.isHealthSyncEnabled) {
```


- [ ] **Step 5: Run everything**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` and `+121: All tests passed!`

Run the iOS build command from the Global Constraints.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart lib/services/siri_buffer_service.dart test/widget_test.dart
git commit -m "fix(siri): take the buffer through the native channel"
```

---

### Task 7: Device checklist

Two-device behaviour can't be tested in CI. Record what has to be checked by hand before this ships.

**Files:**
- Modify: `docs/superpowers/plans/2026-09-20-icloud-sync.md` (this file — replace the "pending" line below with the results)

- [ ] **Step 1: Run the checklist on two devices signed into the same iCloud account**

Both on the new build unless a step says otherwise.

- [ ] Delete an item on A → it disappears on B within a few seconds, with the app open on B (this is the live-sync path, #4).
- [ ] Delete an item on A, then force-quit and reopen B → the item is still gone (the marker survived, #5).
- [ ] Undo a delete on A → the item comes back on B.
- [ ] "Reset today" on A → B empties too.
- [ ] Log food on both with B in airplane mode, then bring B back online → both items are on both devices, newest first.
- [ ] Remove a favourite on A → it's gone on B. Re-add it on B → it comes back on A.
- [ ] "Reset favourites" on A → B's list empties.
- [ ] Change the carb goal on A → B shows the new goal. Then change the reset hour on B → A follows, and A's earlier goal change is not undone.
- [ ] Sign out of iCloud on A, change something → the failed-sync icon appears and stays; sign back in and change something → it syncs (#13).
- [ ] With the app killed, ask Siri to log two foods in a row, then open the app → both appear once, and the buffer doesn't re-import on the next launch.
- [ ] Leave one device on the old build: deletes made there may still come back — expected, and worth confirming it's only that direction.

- [ ] **Step 2: Record the results and commit**

Replace the line below with the date, the devices and iOS versions, and anything that failed.

> Device checklist: pending.

```bash
git add docs/superpowers/plans/2026-09-20-icloud-sync.md
git commit -m "docs: record the two-device checklist results"
```

---

## Notes for the reviewer

- The merge is deliberately allowed to run more than once: `_applyCloudData` merges on launch, on resume and on every remote change, and `syncStateDiffers` decides whether to push back. If a change makes merging non-idempotent, the two devices will push at each other continuously.
- `lib/services/sync_merge.dart` has no I/O by design. Anything reaching for SharedPreferences, channels or `DateTime.now()` inside it belongs in `sync_store.dart` or `main.dart`.
- Deletes are recorded *before* `_saveData()` pushes, not after. `_saveAfterDeleting` exists for that ordering; calling `_saveData()` directly from a delete path loses the marker from that push.
- `CloudSyncStore.dataKeys` is the allow-list for pulls. A new synced key that isn't in it is silently dropped on the way in — which is how this batch's three keys would quietly fail to sync.
