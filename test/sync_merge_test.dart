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

    test('a marker keeps the item out; dropping it on undo lets it back', () {
      final deleted = merge(
        state(items: [item('a', 'Apple')], deleted: {'a'}),
        state(items: [item('a', 'Apple')]),
      );
      expect(deleted.items, isEmpty, reason: 'the marker should win');

      // Undo drops the marker here and pushes, so the cloud copy stops
      // carrying it too.
      final restored = merge(
        state(items: [item('a', 'Apple')]),
        state(items: [item('a', 'Apple')]),
      );
      expect(restored.items.map((i) => i.id), ['a']);
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

    test('a delete marker exactly at the 60-day mark is still kept', () {
      final merged = merge(
        state(changes: {
          'bagel': change(now.subtract(const Duration(days: 60)), deleted: true)
        }),
        state(),
      );

      expect(merged.favoriteChanges.containsKey('bagel'), isTrue);
    });

    test('on an exact tie the cloud copy wins and nothing is pushed back', () {
      final at = DateTime(2026, 9, 20, 9);
      final local = state(
        favorites: [item('f-local', 'Bagel', carbs: 40)],
        changes: {'bagel': change(at)},
      );
      final cloud = state(
        favorites: [item('f-cloud', 'Bagel', carbs: 48)],
        changes: {'bagel': change(at)},
      );

      final merged = merge(local, cloud);

      expect(merged.favorites.single.id, 'f-cloud');
      // Matching the payload it just read is what stops this device pushing
      // its own copy straight back at the other one.
      expect(syncStateDiffers(merged, cloud), isFalse);
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

    test('on an exact tie the cloud settings win and nothing is pushed back',
        () {
      final at = DateTime(2026, 9, 20, 9);
      final local = state(settings: SyncSettings(dailyCarbGoal: 100, updatedAt: at));
      final cloud = state(settings: SyncSettings(dailyCarbGoal: 150, updatedAt: at));

      final merged = merge(local, cloud);

      expect(merged.settings.dailyCarbGoal, 150);
      expect(syncStateDiffers(merged, cloud), isFalse);
    });
  });

  group('convergence', () {
    test('an expired delete marker does not resurrect the favourite', () {
      // The other device has been away long enough for the marker to expire
      // and still carries its copy.
      final local = state(changes: {
        'bagel': change(now.subtract(const Duration(days: 61)), deleted: true)
      });
      final cloud = state(favorites: [item('f1', 'Bagel')]);

      final once = merge(local, cloud);
      final twice = merge(once, cloud);

      expect(once.favorites, isEmpty);
      expect(twice.favorites, isEmpty,
          reason: 'dropping the marker while a copy is still around undoes the delete');
    });

    test('a day-key mismatch alone is not worth pushing', () {
      // One device has rolled over to a new day (or is in another time zone).
      // Each device would otherwise read the other's day as a difference and
      // answer its push forever.
      final local = state(items: [item('a', 'Apple')]);
      final cloud = state(dayKey: '2026-09-19', items: [item('b', 'Bagel')]);

      final merged = merge(local, cloud);

      expect(syncStateDiffers(merged, cloud), isFalse);
    });

    test('a favourite change still pushes when the days differ', () {
      final local = state(
        favorites: [item('f1', 'Bagel')],
        changes: {'bagel': change(now)},
      );
      final cloud = state(dayKey: '2026-09-19');

      final merged = merge(local, cloud);

      expect(syncStateDiffers(merged, cloud), isTrue);
    });

    test('merging again changes nothing, so devices stop pushing', () {
      final local = state(
        items: [item('a', 'Apple')],
        deleted: {'x'},
        favorites: [item('f', 'Bagel')],
        changes: {'bagel': change(now)},
        settings: SyncSettings(dailyCarbGoal: 100, updatedAt: now),
      );
      final cloud = state(items: [item('b', 'Bagel', at: DateTime(2026, 9, 20, 9))]);

      // Merge the same cloud payload again — merging the result with itself
      // would pass no matter what the merge did.
      final first = merge(local, cloud);
      final second = merge(first, cloud);

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
