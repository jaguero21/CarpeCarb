# iCloud sync correctness (review #4, #5, #13) — design

Date: 2026-09-20 · Status: approved design, pending implementation plan

## Problem

From the 2026-09-18 code review, plus two issues found while exploring:

- **#4 Live sync never fires.** `CloudSyncStore.pullFromCloud` sets
  `lastKnownTimestamp` (`CloudSyncStore.swift:163`) before `kvStoreDidChange`
  compares against it (`:257`), so the values are always equal and `onChange` is
  never called. Remote changes only arrive at launch and resume.
- **#5 Deletes come back.** Today's list merges as a union by id
  (`lib/main.dart:326-331`) and favourites as a union by name (`:303-307`), with
  nothing recording a deletion. Deleting an item, resetting the day, removing a
  favourite (`lib/screens/settings_page.dart:218`) or "Reset favourites"
  (`:212`) is undone as soon as another device merges. Goals are pushed as part
  of every payload and a `0` means "remove" (`lib/main.dart:276-282`), so a
  device with stale or unset goals wipes the other's.
- **#13 Push reports success when iCloud is off.** `CloudSyncStore.pushToCloud`
  returns nothing (`CloudSyncStore.swift:92`) and `CloudSyncChannel` always
  answers `true` (`CloudSyncChannel.swift:101`), so the app shows the synced
  icon and advances its last-pushed timestamp after a push that did nothing.
- **Fixing #4 exposes a crash.** A same-day reload replaces the list in place
  (`main.dart:428`) without resetting the AnimatedList, which then miscounts
  (RangeError). Today this needs an unlucky overlap; with live sync it would
  happen on every remote change.
- **Siri buffer race (deferred from the Siri batch).** `_importSiriLoggedItems`
  (`main.dart:489`) reads the App Group buffer and clears it in two calls; a
  Siri `addFood` in between is lost.

## Scope

In: #4, #5, #13, the list rebuild, and the Siri buffer take-and-clear.

Out: a timer for the day rollover while the app stays open; iCloud account-switch
handling; anything else from the review.

## Part 1 — what syncs, and how merges work

All merge logic lives in a new pure module, `lib/services/sync_merge.dart`, with
no I/O so it can be tested directly. `main.dart` calls it.

**Today's food list**
- New local key `food_items_deleted`: ids deleted today. Cleared with
  `food_items` on a new day.
- `removeItem` (`main.dart:805`) and `_resetTotal` (`:781`) add ids; undo removes
  the id again.
- Merge runs only when the cloud payload's `last_save_date` is today: the result
  is the union of both sides' items minus the union of both sides' deleted ids,
  sorted newest-first. The deleted-id lists are unioned and kept.
- A cloud payload from another day is ignored for this section entirely — both
  its items and its deleted ids, which belong to that day — and local data is
  left alone.

**Favourites**
- New local key `saved_foods_changes`: `{nameKey: {updatedAt, deleted}}`, where
  `nameKey` is the lower-cased name (the existing dedupe key).
- Recorded by add (`main.dart:1418`), remove and "Reset favourites"
  (`settings_page.dart:218`, `:188`), and undo.
- Merge: per name, the newer change wins; the favourite's details come from the
  winning side. A name with no change record (written by an older build) counts
  as added at epoch 0, so any real change beats it.
- Delete markers older than 60 days are pruned on merge.

**Goals and reset hour**
- New local key `settings_updated_at`, set when the user changes settings
  (`_applySettingsResult`), never when cloud data is applied.
- Cloud settings are applied only when the cloud's `settings_updated_at` is
  greater than the local one. A device that has never changed settings (key
  absent) adopts the cloud's, which keeps fresh-install behaviour.

**Push-back and convergence**
- After merging, push only when the merged state differs from the payload that
  came from the cloud. "Differs" compares exactly what is synced: today's items
  and deleted ids, the favourites list and its change map, and the settings
  values with their timestamp — not `cloud_last_modified`, which changes on
  every push. Both devices therefore settle instead of ping-ponging.
- Launch, resume and live change all run the same merge, so the newer-than gate
  in `_initCloudSync` (`main.dart:221-227`) goes. `cloud_last_modified` stays in
  the payload: the native pull uses it to decide whether the cloud has data.

## Part 2 — native fixes

**`CloudSyncStore.swift`**
- `kvStoreDidChange`: capture `lastKnownTimestamp` before pulling and compare the
  pulled timestamp against that captured value, via a pure
  `static func isNewRemoteChange(previous: String?, pulled: String?) -> Bool`.
- `dataKeys` (`:41`) gains `food_items_deleted`, `saved_foods_changes` and
  `settings_updated_at`; keys not listed there are dropped by the pull.
- `pushToCloud` returns `Bool`: false when iCloud is unavailable, the payload is
  empty, or `synchronize()` returns false.
- For tests, the store takes its key-value store behind a small protocol
  (default `NSUbiquitousKeyValueStore.default`) and its availability check as a
  closure, so tests use an in-memory fake.

**`CloudSyncChannel.swift`**
- `handlePushToCloud` returns the store's result instead of a constant `true`
  (`:101`).

**`lib/services/cloud_sync_service.dart`**
- `pushToCloud` returns what the channel answered instead of `true` whenever the
  call didn't throw (`:38-44`). Without this the Swift fix changes nothing: Dart
  would still report every push as a success.

**Siri buffer take-and-clear**
- `CarbDataStore` gains `@MainActor takeSiriLoggedItems() -> String?`: returns
  the buffer and removes it in one main-actor step.
- New `ios/Runner/SiriBufferChannel.swift` exposes it on
  `com.carpecarb/siribuffer`, registered in `AppDelegate` and added to the Xcode
  project the way `SiriAuth.swift` was.
- New `lib/services/siri_buffer_service.dart` calls it;
  `_importSiriLoggedItems` uses it instead of `HomeWidget.getWidgetData` plus
  `saveWidgetData(null)`.
- Accepted cost: the buffer is cleared before it is parsed, so a corrupted
  buffer, or one taken moments before the app is killed, is lost. That is the
  price of closing the race, and a valid Siri-written buffer always parses.

**List rebuild**
- The same-day branch of `_loadSavedData` assigns a fresh `_listKey`
  (`main.dart:90` becomes non-final) when it replaces the list wholesale, so the
  AnimatedList is rebuilt at the new count. Single add/remove animations are
  unaffected; wholesale reloads lose the entrance animation.

## Part 3 — flows, migration, errors

**Flows**
- Local change: save locally, then push the full payload (now including deleted
  ids, favourite changes and `settings_updated_at`).
- Launch: listen, pull, merge, push if the merge changed anything.
- Resume: the same, after `_onResumed` has handled a new day.
- Remote change: merge, then push only if the merge changed anything.

**Migration**
- A payload without the three new keys reads as: no deleted ids, no favourite
  changes (existing favourites count as epoch 0), settings timestamp 0.
- While one device still runs the old build, deletes can still come back from
  it; two updated devices resolve deletes correctly.
- Nothing local is discarded on update: the new keys start empty.

**Errors**
- A failed push shows the existing failed icon and leaves the last-pushed
  timestamp alone, so the next change retries.
- A pull with no cloud data leaves local data untouched.
- Each section of a cloud payload is parsed defensively; a section that can't be
  read is skipped rather than wiping its local counterpart.
- A Siri buffer that can't be parsed is logged and dropped.

## Post-review amendments

Found by the whole-branch review and fixed before merge; each changes what an
earlier section of this spec says, so the amendment wins.

- **A favourite's delete marker is kept while either side still holds the
  favourite**, not pruned purely on age. Dropping it at 60 days while the other
  device's copy is still in the payload let that copy win the next merge, so the
  delete undid itself — merging the same payload twice differed from merging it
  once.
- **A day-key mismatch is not a reason to push back.** `syncStateDiffers`
  compares only the day-independent sections when the two sides are on different
  days. Otherwise each device reads the other's day as a difference and answers
  its push forever — two devices in different time zones, or one that hasn't
  rolled over yet. Local changes still push on their own.
- **Goals from an older build are stamped once on upgrade**
  (`SyncStore.stampExistingSettings`). "Never changed here" and "changed before
  this build existed" were indistinguishable, so a device that had never set a
  goal could look newer and wipe a device that had — the third bullet of #5,
  surviving on the upgrade path this spec's Migration section claimed to cover.
- **The resume merge waits for the new-day handling** instead of racing it, as
  Part 3 always intended.
- **Stored-state read-modify-write cycles are serialized.** A merge spans
  several awaits; a local save landing in the gap was overwritten by the merge's
  write, and the item the user had just added vanished from the list. Live sync
  is what made this window reachable.

## Testing

- **`test/sync_merge_test.dart`** (the pure module, where the risk is): a delete
  propagates and stays deleted through later merges; undo restores; reset-today
  clears both devices; items added on two devices while apart both survive;
  favourites — newest add-or-delete per name wins, "Reset favourites"
  propagates, re-adding after a delete wins, markers older than 60 days are
  pruned; settings — newer wins, a never-changed device adopts the cloud's, a
  stale device doesn't wipe goals; old-build payloads are handled; merging twice
  is a no-op the second time (what makes push-back settle).
- **Widget test:** a remote change that replaces the list with a different number
  of items rebuilds it with no range error.
- **Swift (`swift test`):** `isNewRemoteChange`; `pushToCloud` false when iCloud
  is unavailable and true on success, against the in-memory fake;
  `takeSiriLoggedItems` returns the buffer and leaves it empty.
- **By hand, two devices:** delete an item on A → gone on B; delete a favourite
  on A → gone on B; log on both with one in airplane mode, then reconnect → both
  items survive; change a goal on A → B follows; sign out of iCloud → the failed
  icon appears.
