# CarpeCarb

[App Store](https://apps.apple.com/us/app/carpecarb/id6759311106) · [Website](https://jaguero21.github.io/CarpeCarb/) · [Privacy policy](https://jaguero21.github.io/CarpeCarb/privacy-policy.html)

A carb tracker for iPhone and iPad. Type what you ate in plain words, like "two slices of sourdough" or "a turkey sandwich on wheat", and CarpeCarb finds the carbs, protein, fat, fiber and calories and adds them to today's log. Every food shows where its numbers came from: USDA, the web, or you. If no reliable carb count turns up, the app asks you to enter one instead of guessing.

## Features

- **Plain-language lookup:** one entry can hold several foods. Brand and chain foods are matched in USDA FoodData Central first.
- **Source labels:** every food is tagged USDA, Web or Manual.
- **Your day by meal:** breakfast, lunch, dinner and snacks, each with its own carb total.
- **Saved and recent foods:** chips under the food field log a food again in one tap, with no lookup.
- **Edit after logging:** change a food's serving (from USDA portions), number of servings, time or meal, and the totals follow.
- **Enter carbs yourself:** log a food and its carbs by hand at any time.
- **Goals:** a daily carb goal with a progress bar, optional protein, fat, fiber and calorie goals, and a day that resets at the hour you choose.
- **Clear today with Undo:** from the ⋯ menu next to TODAY, after a confirmation.
- **Apple Health:** writes nutrition for every food and keeps it right through edits and Undo. History shows the last 30 days from Health.
- **iCloud sync:** today's log, saved foods and goals stay in step between iPhone and iPad.
- **Siri, Shortcuts and a Home Screen widget:** "Log food in CarpeCarb", "How many carbs today in CarpeCarb", and today's total at a glance.
- **Free with a subscription option:** 4 lookups a day free, with every feature included. A subscription removes the daily limit.
- **Accessibility:** VoiceOver labels throughout, large text layouts, and light and dark themes.

## How a lookup works

1. The app or Siri sends the food text to the `getMultipleCarbCounts` Cloud Function. The request is signed with a Firebase anonymous-auth ID token, so there's no account.
2. The server checks the per-user rate limit and, for free users, the daily quota (both in Firestore).
3. The text is split into foods (Perplexity `sonar`). Foods with a named brand or chain are searched in USDA FoodData Central. Every other food, and any brand food USDA can't match, goes through a chain: a web lookup (`sonar-pro`), then USDA survey data (FNDDS), then the web lookup once more.
4. USDA numbers are calculated on the server from FoodData Central data, with the portions the serving picker offers. A 0 g answer needs two sources to agree. A food with no reliable carb count comes back as unknown, and the app asks the user to enter it.

## Architecture

```
┌──────────────────────┐   HTTPS (callable)  ┌──────────────────────────┐      ┌───────────────────────┐
│ Flutter app          │ ──────────────────► │ Firebase Cloud Functions │ ───► │ USDA FoodData Central │
│ Siri (App Intents)   │ ◄────────────────── │ keys in Secret Manager   │ ───► │ Perplexity API        │
│ no keys in the app   │   anonymous auth    │ quota + rate limits in   │ ───► │ App Store Server API  │
└──────────────────────┘                     │ Firestore                │      └───────────────────────┘
          │                                  └──────────────────────────┘
          ├── SharedPreferences: today's log, saved and recent foods, goals
          ├── Apple HealthKit: nutrition writes, 30-day history
          ├── iCloud key-value store: today's log, saved foods, goals
          └── App Group: Home Screen widget and Siri share today's data
```

## Tech stack

| Layer | Technology |
|-------|-----------|
| **App** | Flutter (Dart), iOS and iPadOS 26 or later |
| **Native iOS** | Swift: App Intents for Siri and Shortcuts, a WidgetKit widget, the iCloud sync bridge, and the `CarbShared` package that the widget and Siri share |
| **Backend** | Firebase Cloud Functions v2 (Node 22): `getMultipleCarbCounts` and `validateAppStoreReceipt` |
| **Nutrition** | USDA FoodData Central, and the Perplexity API (`sonar` to parse and match, `sonar-pro` for web lookups) |
| **Auth and data** | Firebase anonymous auth. Firestore holds rate limits, daily quotas and subscription records ([firestore.rules](firestore.rules)) |
| **Secrets** | Google Cloud Secret Manager. No API key ships in the app |
| **Purchases** | StoreKit through `in_app_purchase`, verified on the server with Apple's App Store Server Library |
| **On device** | SharedPreferences, HealthKit (the `health` package), iCloud key-value store, App Group |

## Project structure

```
lib/
  ├── main.dart                 # App entry and the home screen
  ├── models/                   # FoodItem, ServingInfo, meal sections, sources, quick log, clear today
  ├── services/
  │   ├── perplexity_firebase_service.dart   # Calls getMultipleCarbCounts
  │   ├── lookup_api.dart                    # Parses its response
  │   ├── health_kit_service.dart            # Apple Health
  │   ├── cloud_sync_service.dart, sync_*.dart  # iCloud sync and merging
  │   ├── premium_service.dart, purchase_service.dart  # Daily limit and subscriptions
  │   ├── recent_foods.dart, rating_prompt.dart
  │   └── siri_import.dart, siri_buffer_service.dart   # Foods Siri logged while the app was closed
  ├── screens/settings_page.dart             # Saved, History, Goals and Features tabs
  ├── widgets/                  # Serving picker, quick-log chips, meal headers, source tags, …
  ├── config/                   # Colors, icons, theme, storage keys
  └── utils/                    # Input rules, dates, accessibility labels, snack bars
functions/
  ├── index.js                  # Cloud Function definitions and secrets
  ├── src/                      # Handlers, lookup chain, USDA, Perplexity, quota, rate limit, App Store
  └── test/                     # node --test suites
ios/
  ├── Runner/                   # AppDelegate, Siri intents and phrases, iCloud and Siri channels
  ├── CarbShared/               # Swift package shared by the widget and Siri
  └── CarbWiseWidget/           # Home Screen widget
docs/                           # Website, deployed to GitHub Pages by .github/workflows/pages.yml
test/, integration_test/        # Widget and unit tests; on-device integration tests
```

## Getting started

You need Flutter (stable), Xcode 26, CocoaPods, Node 22 and the Firebase CLI.

```bash
flutter pub get

# Generates lib/firebase_options.dart and ios/Runner/GoogleService-Info.plist,
# which aren't committed
flutterfire configure --project=<firebase-project> --platforms=ios

flutter run
```

### Backend

```bash
cd functions && npm install

# Each command prompts for the value; keys live only in Secret Manager
firebase functions:secrets:set PERPLEXITY_API_KEY
firebase functions:secrets:set USDA_API_KEY
firebase functions:secrets:set APP_STORE_IAP_KEY     # also APP_STORE_KEY_ID, APP_STORE_ISSUER_ID, APP_APPLE_ID

firebase deploy --only functions,firestore:rules
```

Siri calls the function by URL, so a different Firebase project also needs `cloudFunctionURL` changed in `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift`.

## Tests

```bash
flutter analyze
flutter test                                       # widget and unit tests
(cd functions && npm test)                         # Cloud Functions
flutter test integration_test/app_test.dart -d <simulator-id>
```

CI runs `flutter analyze` on every pull request.

## Privacy

No account and no ads. Lookups are tied only to an anonymous ID, and the server doesn't keep the food text. Apple Health data never leaves the device, and iCloud data stays in the user's own account. See the [privacy policy](https://jaguero21.github.io/CarpeCarb/privacy-policy.html).

CarpeCarb is for tracking and awareness, not medical advice. Its numbers are estimates.

## License

Apache 2.0. See [LICENSE](LICENSE).
