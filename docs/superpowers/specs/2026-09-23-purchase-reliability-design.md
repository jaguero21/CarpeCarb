# Purchase reliability and cleanup — design

Review items #11 (purchase-lock window) plus three cleanup items. Out of scope:
`minInstances: 1` in `functions/index.js:102` (deliberately kept warm), and
iOS 27 adoption, which is its own batch.

## Part 1 — why the purchase path loses money

Four facts about the code as it stands, each verified by reading it:

1. **There is no app-level purchase listener.** The only two
   `_iap.purchaseStream.listen(...)` calls are inside `purchasePlan`
   (`lib/services/purchase_service.dart:153`) and `restorePremiumPlan`
   (`:238`), and both subscriptions are cancelled when their method returns.
   Any transaction that arrives outside those two windows is observed by
   nobody.

2. **`completePurchase` is therefore never called for those transactions**, so
   StoreKit keeps them in the queue while the user has already been charged and
   has no premium. The paths that hit this are not exotic:
   - the 90-second timeout at `:225` fires, `finally` cancels the subscription,
     and a confirmation arriving at 91 seconds lands on nothing;
   - **Ask to Buy** (Family Sharing parental approval), which can take hours or
     days;
   - a purchase interrupted by a crash or a force-quit, which StoreKit
     re-delivers at the next launch.

   The user's only recovery is to guess that tapping Restore will help.

3. **Premium is granted by the UI, not by the service.** `settings_page.dart`
   calls `setPremiumEnabled` at `:1668` after `purchasePlan` returns and at
   `:1708` after a restore. So even if a listener did observe a late
   transaction, nothing would grant anything.

4. **The lock guards almost nothing.** `_purchaseInProgress` (`:19`) is an
   instance field, and `PurchaseService` is constructed per `SettingsPage`
   (`settings_page.dart:81`). `SettingsPage` is keyed `ValueKey(_settingsInitialTab)`
   (`main.dart:1716`) and the premium "View Plans" path sets that to `3`
   (`main.dart:725`) — which rebuilds the State, constructs a fresh
   `PurchaseService`, and resets the lock while a purchase is still running.
   `restorePremiumPlan` never takes the lock at all, so a restore can run
   concurrently with a purchase: two listeners on one stream, both validating
   and both calling `completePurchase` on the same transaction.

### The shape that fixes it

One `PurchaseService` singleton owning **one `purchaseStream` subscription that
lives as long as the app**, started from `main()` after Firebase is initialised
(`main.dart:38-62`) and never cancelled. That listener is the only code that
validates a receipt, completes a transaction, and grants premium. Whether a
screen is waiting makes no difference to how a transaction is handled — which is
the property the current design lacks.

Per transaction:

- **`purchased` or `restored`** → validate the receipt server-side
  (`_validateReceipt`, unchanged), then `completePurchase`, then
  `setPremiumEnabled(true, plan:)`, then emit an outcome event.
- **No Firebase ID token yet** → do **not** call `completePurchase`, and do not
  grant. Leave the transaction in the queue and re-attempt when a token becomes
  available, driven by `FirebaseAuth.instance.authStateChanges()`. StoreKit
  re-delivers an uncompleted transaction, so holding is safe and dropping is
  not. Completing an unvalidated purchase would be the one unrecoverable
  mistake here: the transaction is gone from the queue and the receipt can no
  longer be checked.
- **`error` or `canceled`** → `completePurchase` to clear the queue, and emit a
  failure so any waiter reports it.

`purchasePlan` and `restorePremiumPlan` become waiters on that listener rather
than owners of it. They take a lock that now lives on the singleton, so a
rebuilt `SettingsPage` cannot reset it and the two flows cannot overlap. The
90-second timeout stays, but it now bounds only *the waiter*: on timeout the UI
reports that confirmation is taking too long, while the listener remains and a
late confirmation still validates, completes and grants.

### What the user sees

A grant that happens with no screen waiting emits on a broadcast stream the app
subscribes to. In the foreground that shows a brief confirmation; in the
background nothing is shown and the premium state is simply already correct when
the app is next opened. The user was charged, so they are told it landed — and
it explains why the paywall disappeared.

### Testability

`PurchaseService` currently hardcodes `final InAppPurchase _iap = InAppPurchase.instance`
(`:18`), which is why none of the above can be tested today. `InAppPurchase` and
`PremiumService` become constructor-injected, with the singleton supplying the
real ones. Tests then drive a fake `purchaseStream` directly.

The cases worth testing are the ones that lose money:

- a `purchased` event with no waiter grants premium and completes the
  transaction;
- a `purchased` event with no auth token neither completes nor grants, and a
  later auth state change makes it do both;
- a waiter that times out does not stop a later event from granting;
- `purchasePlan` while another purchase is in flight is refused, and the same
  holds for a restore;
- an `error` event completes the transaction and reports the failure rather
  than hanging.

## Part 2 — cleanup

### The app's old name

`pubspec.yaml:2` still reads `description: biteBot - A minimalist carb tracking
app using Perplexity API`, and `android/app/src/main/AndroidManifest.xml:3` sets
`android:label="biteBot"`. Both become CarpeCarb.

### Hardcoded colours

8 `Color(0x...)` literals sit in view code, against a comprehensive palette in
`lib/config/app_colors.dart`. Some literals are exactly a constant that already
exists — `0xFFE8A93C` is `AppColors.honey`, `0xFFD4714E` is `AppColors.terracotta`
— while three category colours match nothing:

| Literal | Nearest existing | Verdict |
|---|---|---|
| `0xFF7D9B76` | `sage` = `0xFF8FA088` | different colour |
| `0xFFB07CC6` | `plum` = `0xFF7B4F72` | different colour |
| `0xFF5B9BD5` | `sky` = `0xFF5B8DB8` | different colour |

The three get their own named constants at their current values. Exact matches
point at the constant they already equal. **No pixel changes**, and a test pins
each category colour to its current value so the refactor cannot quietly restyle
the app.

### Unused entitlements

`ios/Runner/Runner.entitlements` claims capabilities the app does not use:

- `aps-environment` — there is no push notification code anywhere in `lib/` or
  `ios/Runner/`; the only match for "messaging" is `messagingSenderId` in
  `firebase_options.dart`, which is ordinary Firebase config.
- `com.apple.developer.icloud-services` (`CloudKit`, `CloudDocuments`),
  `icloud-container-identifiers`, `icloud-container-environment` and
  `ubiquity-container-identifiers` — sync is `NSUbiquitousKeyValueStore` only
  (`ios/CarbShared/Sources/CarbShared/CloudSyncStore.swift`). No `CKContainer`,
  no ubiquity document URLs.

Kept: `ubiquity-kvstore-identifier` (what KVS actually needs), HealthKit, Siri,
application groups, and `keychain-access-groups`.

`ios/Runner/Runneralpha.entitlements` is referenced by no build configuration —
`CODE_SIGN_ENTITLEMENTS` in `project.pbxproj` names only `Runner/Runner.entitlements`,
the widget's, and the Watch app's. It also carries a *different*, hardcoded
kvstore identifier (`$(TeamIdentifierPrefix)com.jamesaguero.mycarbtracker` rather
than `$(CFBundleIdentifier)`), so leaving it invites someone to wire up the wrong
one later. It is deleted.

This lands last, in its own commit, because entitlements drive provisioning and
signing and this is the item most likely to need reverting. It cannot be verified
by any automated test here: it needs a device check that iCloud sync still carries
data between devices.

## Order

1. The old name — text only.
2. Colours — mechanical, guarded by a pinning test.
3. The purchase path — several tasks, the substance of the batch.
4. Entitlements — isolated, revertable, device-verified.

## Checks

`flutter analyze && flutter test` from the repo root; `cd ios/CarbShared && swift test`;
and the iOS build with its own DerivedData so it cannot leave ad-hoc-signed
frameworks in the cache Xcode uses:

```
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/purchase-dd \
  CODE_SIGNING_ALLOWED=NO build
```

## Device checklist (James)

- Buy a subscription in the sandbox; confirm premium is granted and the
  transaction does not reappear at next launch.
- An Ask to Buy purchase approved later grants premium without tapping Restore.
- Restore on a second device grants premium.
- iCloud sync still moves data between two devices after the entitlements change.
- The app still installs and runs on device after the entitlements change.
