# Serving Picker — Design

**Date:** 2026-10-12
**Release:** 1.0.4
**Status:** Approved in conversation; awaiting spec review

## Problem

A looked-up food is logged at whatever serving the lookup chose. "beef tacos"
logs one taco; a USDA "typical serving" of pizza is 296 g. Today a logged food
can only be deleted, so the user's only way to correct a serving is to delete
the food and enter the carbs by hand.

Since PR #58 the server returns, for USDA foods, everything needed to change the
serving on the device: `source: "usda"`, `fdcId`, `serving {portionId, label,
grams, count}`, `portions [{id, label, grams}]` and `per100g {carbs, protein,
fat, fiber, calories}`. Web foods carry `source: "web"` and no portions.

## Decisions

1. **Where:** in the food's details dialog. Logging stays one tap.
2. **Web foods:** a servings count (½ steps) that scales the looked-up values.
   USDA foods get the serving list plus the count. Manual entries get no picker.
3. **Siri:** full picker. Foods logged by voice carry the same serving data.
4. **Stored numbers stay the source of truth.** An edit recalculates carbs and
   macros once and saves them on the food, so every existing reader (day total,
   widget, Apple Health, iCloud, older app versions) is unchanged.

## Data

`FoodItem` gains two optional fields.

**`serving`** (`ServingInfo?`):

| Field | USDA food | Web food |
|---|---|---|
| `source` | `"usda"` | `"web"` |
| `fdcId` | from the server | — |
| `portions` | from the server, `[{id, label, grams}]` | — |
| `per100g` | from the server | — |
| `portionId` | chosen serving; initially the server's `serving.portionId` | — |
| `count` | initially the server's `serving.count` | initially 1 |
| `base` | — | carbs, protein, fat, fiber, calories at count 1 (the looked-up values) |

**`updatedAt`** (`DateTime?`): set on every edit; null for a food never edited.

Recalculation:
- USDA: each nutrient = `per100g × portion.grams × count / 100`.
- Web: each nutrient = `base × count`.
- A nutrient that is null stays null. Results are rounded to 1 decimal as
  `(v * 10).round() / 10`, which matches the server's `Math.round(v * 10) / 10`.

Count: steps of ½, from ½ to 20 (the server's accepted range is 0.25–20).

A food with no `serving` (foods logged before 1.0.4, manual entries, foods
saved by a device still on 1.0.3) behaves exactly as today and shows no picker.
Saving a food to Favorites keeps its `serving`, so relogging a favorite stays
adjustable.

JSON: `serving` and `updatedAt` are written only when present, so payloads for
foods without them are unchanged.

## Interface

**Food row.** The time label gains the serving:
- USDA: "7:45 AM · typical serving (270 g)", or "7:45 AM · 2 × 1 cup (240 g)"
  when the count isn't 1.
- Web: "7:45 AM · ×2" when the count isn't 1; nothing extra at 1.

**Details dialog.** A "Serving" section above the macro tiles:
- USDA: a menu of the portions with weights ("1 cup · 120 g", "typical serving
  · 270 g", "100 g") and a count stepper (− ½ +).
- Web: the count stepper only, labelled "servings of what was looked up". The
  details text below still names the looked-up serving.

Behaviour:
- Carbs and macro tiles preview live, with the original carbs shown faintly
  ("was 28.6 g").
- An **Update** action appears only after a change. **Close** discards the
  change.
- On Update, the food is saved with recalculated values and `updatedAt = now`.
  A snackbar confirms: "Updated to 57.2 g". The day total and widget refresh.

Accessibility:
- Stepper buttons are labelled "Fewer servings" and "More servings"; the
  stepper value reads "2 servings".
- Each step announces the new carb total ("57.2 grams of carbs").
- The portion menu is a standard picker whose options include their weight.
- The section follows the existing large-text rules; the dialog already scrolls.

## iCloud sync

`mergeSyncState` currently keeps the cloud's copy when both devices hold the
same food id ([sync_merge.dart:158-161](../../../lib/services/sync_merge.dart)).
With editing, the copy with the later `updatedAt` wins. A null `updatedAt` is
older than any timestamp; on a tie (including both null) the cloud's copy wins,
as today, so both devices reach the same result.

A device on 1.0.3 drops `serving` and `updatedAt` when it saves. Its copy then
has no `updatedAt`, so an edit made on 1.0.4 still wins. An unedited food that
passes through a 1.0.3 device can lose its `serving`; its carbs stay correct,
and it simply has no picker.

## Apple Health

On Update, the food's sample is replaced, never duplicated:
1. Delete the food's sample in its own window (`healthDeleteWindow(loggedAt)`),
   so other foods are untouched.
2. Only if the delete succeeds, write the new values at the same `loggedAt`.
3. If either step fails, show the existing Health sync error. The edit stays
   saved in the app.

## Siri

- `PerplexityClient.swift` parses `source`, `fdcId`, `serving`, `portions` and
  `per100g` into `LookupItem`.
- `LoggedFood` gains an optional serving (Codable), stored by `CarbDataStore`
  with the rest of the Siri-logged item.
- `siri_import.dart` maps it into `FoodItem.serving`. A web food from Siri gets
  `base` from its values and `count: 1`.
- Siri's spoken reply doesn't change.

## Server

No change. The response already carries every field above.

## Out of scope

- Editing past days (history comes read-only from Apple Health).
- A picker for manual entries.
- Changing the serving before a food is logged.

## Testing

Unit tests:
- `ServingInfo` recalculation for USDA and web, with nulls and rounding that
  matches the server for the same inputs (e.g. 5.6 g/100 g × 245 g × 3 = 41.2).
- `FoodItem` JSON round trip with and without `serving` and `updatedAt`; old
  JSON without them still loads.
- `lookup_api` parsing: a USDA item fills `serving` from the response; a web
  item gets `base` and `count: 1`; a manual entry gets none.
- `mergeSyncState`: the later `updatedAt` wins from either side; a null loses to
  any timestamp; equal timestamps keep the cloud copy.
- Health update: delete then write; no write if the delete fails.
- Siri import: a stored serving reaches `FoodItem.serving`.
- Swift: `LookupItem` parsing of the new fields; `CarbDataStore` round trip.

Widget tests:
- Details dialog: Update appears only after a change; Close discards; Update
  saves recalculated values and refreshes the total.
- Accessibility labels and announcements for the stepper.

Device check before release: change a USDA food's serving and a web food's
count; confirm the total, the widget, the Apple Health entry and a second
device all update.
