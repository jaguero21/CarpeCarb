# USDA FoodData Central Lookup — Design

**Date:** 2026-09-28
**Status:** Approved in conversation; awaiting spec review
**Builds on:** PR #54 (unsourced-zero guard, US default)

## Problem

Food lookups ask Perplexity `sonar-pro` to search the web and write the
nutrition numbers itself. Live-model probes on 2026-09-28 (5 runs per food)
showed the limits of that:

- Generic dishes return nothing: "pho" was null 5/5.
- Chain items are inconsistent: McDonald's 4-piece McNuggets came back as
  11 g twice and 18–19 g three times. The US value is about 10 g.
- Each prompt change moved failures around rather than removing them. One
  version made "pizza" null 4/5.

People use these numbers to dose insulin. The same input should give the same
number, and the number should come from a named source.

## Evidence that USDA covers the gap

Checked against the FoodData Central API:

| Food | FDC entry | Carbs / 100 g | Portions listed |
|---|---|---|---|
| pho | FNDDS 2707124 "Soup, pho, with meat" | 5.6 | 1 cup = 245 g |
| McNuggets | SR Legacy 173297 "McDONALD'S, Chicken McNUGGETS" | 15.1 | 4 pc = 64 g, 6 pc = 95 g, 10 pc = 159 g |
| Big Mac | FNDDS 2706916 "Big Mac (McDonalds)" | 21.53 | 1 sandwich = 205 g |

4 McNuggets = 15.1 × 0.64 = 9.7 g, the correct value, and it is the same on
every run.

## Decisions

1. **Serving size:** the server picks it. It uses the amount the user typed
   ("bowl of pho", "10 nuggets") and otherwise USDA's standard portion.
   `details` always states the portion and its grams. The app is unchanged,
   and a serving adjuster in the app is a possible follow-up.
2. **No USDA match:** fall back to today's web lookup (with the #54 guard) and
   label the result in `details`.
3. **AI vendor:** Perplexity only, with `disable_search: true` for the parse
   and pick calls. The consent screen and the AI part of the privacy policy
   stay accurate.
4. **Numbers:** always calculated by the server from USDA data. The model
   supplies IDs and a count, never nutrition values, on the USDA path.

## Architecture

```
text ──► parse (sonar, search off) ──► [{name, query, amount}]
            │
            ▼ per food, in parallel
        USDA search: Survey (FNDDS), SR Legacy, Foundation, Branded
            │ top 8 candidates; one details call adds portions for SR Legacy / Foundation
            ▼
        pick (sonar, search off, ONE call for all foods) ──► per food {fdcId, portionId, count} | none
            │
   ┌────────┴─────────┐
 valid match        none / invalid / USDA error / deadline
   │                   │
 server math        web lookup for those foods only (perplexity.js)
```

### Units

- **`functions/src/usda.js`:** talks to FoodData Central. It has no model
  code.
  - `searchFoods(query, apiKey, {fetchImpl, signal})` → candidates:
    `{fdcId, description, dataType, carbsPer100g, proteinPer100g,
    fatPer100g, fiberPer100g, kcalPer100g, portions: [{id, label, grams}]}`.
    Portions come from the search result's `foodMeasures`. SR Legacy and
    Foundation results have none there, so one batched details call
    (`POST /foods`, `format: "full"`) fetches their `foodPortions`; if it fails,
    those candidates keep only the 100 g portion. Branded foods use
    `servingSize`/`householdServingFullText`, and Branded foods measured in ml
    are dropped, because their per-100 values are per 100 ml. FNDDS's
    "Quantity not specified" portion is labelled "typical serving". Every
    candidate also gets a synthetic `100 g` portion. Nutrients are read from
    the search result, not the details call: the details call's nutrient filter
    returned nothing for SR Legacy.
  - `nutritionFor(candidate, portion, count)` → `{carbs, protein, fat, fiber,
    calories}`, where each value = per-100 g × grams × count / 100, rounded to
    1 decimal. A nutrient USDA does not list stays null, never 0. Carbs are
    FDC nutrient 1005 (carbohydrate, by difference).
- **`functions/src/foodParse.js`:** prompts and output validation for the two
  model calls.
  - `parseFoods(text, apiKey, deps)` → `[{name, query, amount}]`, where
    `amount` is the user's words for quantity, or null.
  - `pickMatches(foods, candidateLists, apiKey, deps)` → one raw pick per
    food, from a single call covering every food that has candidates. The model
    sees descriptions, brands and portions, never nutrition values.
  - `validatePick(pick, candidates)`: `fdcId` must be among the candidates,
    `portionId` must belong to that candidate, and `count` must be a finite
    number with 0.25 ≤ count ≤ 20. Anything else counts as no match.
- **`functions/src/lookup.js`:** orchestration. `lookupFoodsUsda(text, keys,
  deps)` returns the same `{items, citations}` shape as today's `lookupFoods`,
  so `handlers.js` only changes which function it calls.
- **`functions/src/perplexity.js`:** unchanged, and becomes the fallback.

### Output per food

- **USDA match:** `name` is the parsed name. `details` is `"USDA FoodData
  Central (<dataType>): <description>, <count × portion label> (<grams> g)."`
  `citations` gains `https://fdc.nal.usda.gov/food-details/<fdcId>/nutrients`.
- **Fallback:** the web lookup's item, with `details` prefixed by
  `"Web source, not USDA. "`.
- The response shape is unchanged. Siri (`PerplexityClient.swift`) and the app
  need no update.

### Multi-food requests

Each food resolves on its own path. For "burger and fries", the burger can
come from USDA while the fries fall back. All fallback foods go out in one web
lookup, with the user's words for each joined by " and ". USDA items come
first, in the order parsed, followed by the fallback's items. If the fallback
fails after some foods matched USDA, those USDA items still return and the
rest come back with `carbs: null`.

## Failure handling

Any USDA-path problem sends *that food* to the fallback. It never fails the
request.

| Failure | Result |
|---|---|
| USDA 429 / 5xx / network error / >4 s | that food → fallback |
| USDA returns 0 candidates | that food → fallback (skip pick call) |
| parse call fails or output invalid | whole request → fallback (today's behavior) |
| pick call fails, `null`, or fails `validatePick` | that food → fallback |
| USDA path not finished at 12 s | unfinished foods → fallback |
| overall 25 s deadline | whatever is resolved returns; unresolved foods come back with `carbs: null` |

On the 25 s deadline, older builds follow the existing `acceptsUnknownCarbs`
handling in `handlers.js`.

**Billing:** the `billed` tracking in `perplexity.js` extends across every
Perplexity call in the request. A free-tier lookup is refunded only if no
Perplexity call returned 2xx. USDA calls are free and do not count.

**Quota:** one lookup per request, as today.

**Logging:** stage, outcome and timing only, e.g. `usda foods=2 hit=1
fallback=1 ms=4120`. Food text, queries and model output are never logged,
which keeps the existing rule.

## Configuration

- **New secret `USDA_API_KEY`:** a free api.data.gov key (1,000 requests per
  hour), created by the owner and stored in Secret Manager.
- **New param `LOOKUP_SOURCE`** (`usda` | `web`, default `usda`), set in
  `functions/.env`: a kill switch. Setting `web` and redeploying restores
  today's behavior exactly, with no code change.

## Privacy

The USDA search phrase is derived from the food text. It is sent to a US
government API with no user identifiers. `docs/privacy-policy.html` gains one
sentence saying so. The consent screen covers the third-party AI and does not
change.

## Speed

- **USDA path:** parse 1–2 s, parallel searches 0.5–1 s, pick 1–2 s, so
  typically 3–5 s. Today's lookup often takes 5–10 s.
- **Fallback:** adds one web call, only for unmatched foods.
- **Limits:** the 25 s cap keeps Siri (30 s client timeout) working. The app's
  timeout is 60 s.

## Testing

**Unit tests** (`node --test`, stubbed fetch) cover:

- match → server-calculated values with the portion and count applied
- pick returns null, an unknown fdcId, an unknown portionId, or a count of 0,
  25 or NaN → fallback
- USDA 429, 500 and timeout → fallback, with the request still succeeding
- parse failure → whole-request fallback
- mixed request with one USDA food and one fallback food → both returned in
  input order
- billing: parse 2xx then failure → stays billed; every call failing with 5xx
  → refunded
- a nutrient missing from USDA → null, never 0
- no food text, query or model output appears in logs
- `LOOKUP_SOURCE=web` → today's code path only

**Math fixtures** come from real USDA records: pho 5.6 × 245 / 100 = 13.7 g
and 4 McNuggets 15.1 × 64 / 100 = 9.7 g.

**Live probe** (scratchpad, key in memory only, never committed), 5 runs each
of: pizza, mcdonalds chicken nuggets, pho, bowl of pho, 10 nuggets, big mac,
banana, water, heb fajita tortilla, grandma's secret casserole, burger and
fries.

The live probe passes when:

- each food gives the same carbs on all 5 runs, or is null on all 5 runs
- pho and nuggets come from USDA
- water is 0
- grandma's secret casserole is null
- median latency is no worse than today

## Out of scope

- A serving adjuster in the app
- Caching USDA results
- Non-US databases
