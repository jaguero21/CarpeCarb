# Health Data Trust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a missing carb value from ever being logged as a confident 0 g, make deleting one food remove only that food from Apple Health, and keep users' food text out of server logs.

**Architecture:** The model is allowed to answer "unknown" (`"carbs": null`). The server keeps that `null` for clients that send `acceptsUnknownCarbs: true` and filters it out for older builds, which would turn it into 0. The app and Siri keep unknown foods out of their food models entirely: the app hands them to Manual entry, and Siri names them and skips them. Separately, every Health entry the app writes starts in its own millisecond, so a delete can match exactly one entry with a 1 ms, start-only window.

**Tech Stack:** Firebase Cloud Functions (Node 22, `node --test`); Flutter 3.41 / Dart 3.11, `flutter_test`, `health` 13.3.2; Swift 6.4 toolchain (package in Swift 5 mode), Swift Testing, App Intents.

**Spec:** `docs/superpowers/specs/2026-09-22-health-data-trust-design.md`

## Global Constraints

- Commits carry NO `Co-Authored-By` or other attribution trailer, and no "Generated with Claude Code" line. Use explicit `git add` paths only. Never stage `.superpowers/`, `build/`, `ios/Pods/`, `lib/firebase_options.dart`, `ios/Runner/GoogleService-Info.plist`, or untracked files you didn't create.
- Branch: `feature/health-data-trust` (the spec is already committed there).
- **Unknown means `null`, never 0.** A food the lookup has no reliable carb value for has `carbs: null`. A real zero (water, black coffee) stays `0`. A missing, non-numeric, negative or non-finite carb value counts as unknown.
- **Capability flag**, spelled exactly: `acceptsUnknownCarbs: true`, sent in the request body next to `tzOffsetMinutes`.
- **Old clients** (no flag) never see a `null`. The server drops the foods it has no carbs for. If none remain, it throws `HttpsError("not-found", "Couldn't find carbs for <names>.")`, naming every dropped food. That error counts toward the free limit like any call Perplexity billed. The quota rule itself is unchanged.
- `FoodItem.carbs` (Dart) and `LookupItem.carbs` (Swift) stay non-optional. Unknown foods travel as a separate list of names (`unknownCarbs`).
- Copy, verbatim:
  - App: `Couldn't find carbs for <names> — enter it manually.` (one food) and `… — enter them manually.` (several).
  - Siri: `… I couldn't find carbs for <names>, so I didn't log it.` / `… log them.`
  - Siri when nothing is found, unchanged: `I couldn't find nutrition info for that.`
- **Health delete window**: `[loggedAt, loggedAt + 1 ms)` in whole milliseconds. Foods from one lookup, or one Siri log, are stamped 1 ms apart.
- The server never logs food text or model output, only lengths, counts, attempt numbers, `finish_reason` and status codes.
- Do not run `dart format` over a whole existing file. The repo isn't uniformly formatted, and reformatting buries the change. Format only new files.
- No force unwraps, `try!` or `fatalError` in shipped Swift.
- Checks:
  - `cd functions && npm test`
  - `flutter analyze && flutter test` from the repo root
  - `cd ios/CarbShared && swift test`
  - iOS build from the repo root: `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. Third-party output that is not yours to fix: an `in_app_purchase_storekit` header deprecation warning and two `libtool: warning: '…' has no symbols` lines.

## How to apply the edits in this plan

Every code block here is the exact text that was built and tested. Copy it byte-for-byte. Retyping loses characters: em dashes, curly quotes, and the snackbar's `\u2014` escape, which must stay an escape.

- **New file:** `python3 .superpowers/sdd/extract_block.py TASK_BRIEF --list`, then `extract_block.py TASK_BRIEF N path/to/file`.
- **Edit to an existing file:** each edit is a "replace / with" pair of consecutive blocks.

```bash
python3 .superpowers/sdd/extract_block.py TASK_BRIEF N /tmp/old.txt
python3 .superpowers/sdd/extract_block.py TASK_BRIEF N+1 /tmp/new.txt
python3 .superpowers/sdd/replace_block.py path/to/file /tmp/old.txt /tmp/new.txt
```

If `replace_block.py` reports 0 or 2+ occurrences, stop and report NEEDS_CONTEXT. Don't hand-edit around it.

## File Map

| File | Task | Responsibility |
|---|---|---|
| `functions/src/perplexity.js` | 1 | the prompt allows "unknown"; carbs stay `null`; `splitUnknownCarbs`, `listNames`; no food text in logs |
| `functions/src/handlers.js` | 1 | read `acceptsUnknownCarbs`; filter for older clients |
| `functions/test/perplexity.test.js`, `functions/test/handlers.test.js` | 1 | server tests |
| `lib/services/lookup_api.dart` | 2 | `LookupResult.unknownCarbs`; unknown never becomes a `FoodItem`; foods 1 ms apart |
| `test/lookup_api_test.dart` | 2 | parsing tests |
| `lib/services/health_kit_service.dart` | 3 | `healthDeleteWindow`; exact delete |
| `test/health_kit_service_test.dart` | 3 | new |
| `lib/main.dart` | 4 | `_applyLookupResult`, the Manual hand-off, a test hook |
| `lib/services/perplexity_firebase_service.dart` | 4 | send the flag |
| `test/widget_test.dart` | 4 | hand-off tests |
| `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift` | 5 | `unknownCarbs`; send the flag |
| `ios/CarbShared/Sources/CarbShared/LogFoodDialog.swift` | 5 | name skipped foods |
| `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift` | 5 | millisecond timestamps; `addFoods` |
| `ios/Runner/CarbIntents.swift` | 5 | use `addFoods` and the skipped list |
| `ios/CarbShared/Tests/CarbSharedTests/*.swift` | 5 | Swift tests |

---

### Task 1: Server — unknown carbs and no health text in logs

**Files:**
- Modify: `functions/src/perplexity.js`, `functions/src/handlers.js`
- Test: `functions/test/perplexity.test.js`, `functions/test/handlers.test.js`

**Interfaces:**
- Produces: `lookupFoods` returns items whose `carbs` may be `null`. It also produces `splitUnknownCarbs(items) → {known, unknownNames}` and `listNames(names) → string`, both exported from `perplexity.js`. The handler reads `request.data.acceptsUnknownCarbs`.

- [ ] **Step 1: Write the failing tests**

Update the import at the top of the file and append the tests.

In `functions/test/perplexity.test.js`:

**Edit 1 of 2 — replace:**

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const { sanitizeFoodInput, lookupFoods, isNotBilled } = require("../src/perplexity");

const isInvalidArgument = (err) => err.code === "invalid-argument";

test("sanitizeFoodInput trims and collapses whitespace", () => {
  assert.equal(sanitizeFoodInput("  big   mac\tand fries \n"), "big mac and fries");
});
```

**with:**

```js
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  sanitizeFoodInput, lookupFoods, isNotBilled, splitUnknownCarbs, listNames,
} = require("../src/perplexity");

const isInvalidArgument = (err) => err.code === "invalid-argument";

test("sanitizeFoodInput trims and collapses whitespace", () => {
  assert.equal(sanitizeFoodInput("  big   mac\tand fries \n"), "big mac and fries");
});
```

**Edit 2 of 2 — replace:**

```js
      name: "Apple", carbs: 25, protein: 0.5, fat: 0.3, fiber: 4.4, calories: 95, details: "USDA, 1 medium apple",
    }],
    citations: [],
  });
  assert.equal(fetchImpl.calls, 1);
});
```

**with:**

```js
      name: "Apple", carbs: 25, protein: 0.5, fat: 0.3, fiber: 4.4, calories: 95, details: "USDA, 1 medium apple",
    }],
    citations: [],
  });
  assert.equal(fetchImpl.calls, 1);
});

// ── Unknown carb values (review #12) ──

/** Runs one lookup of a single completion and returns the mapped items. */
async function lookUp(content) {
  const fetchImpl = stubFetch(completion(content));
  const res = await lookupFoods("some food", "key", { fetchImpl, sleep: noSleep });
  return res.items;
}

test("lookupFoods keeps a missing carb value as null, never 0", async () => {
  const [item] = await lookUp('[{"name":"Mystery stew","carbs":null,"details":"No reliable source"}]');

  // A confident 0 g is worse than no answer for someone dosing insulin.
  assert.equal(item.carbs, null);
});

test("lookupFoods keeps a real zero as zero", async () => {
  const [item] = await lookUp('[{"name":"Water","carbs":0}]');

  assert.equal(item.carbs, 0);
});

test("lookupFoods treats negative and infinite numbers as no value", async () => {
  // 1e999 parses to Infinity.
  const [item] = await lookUp('[{"name":"Odd","carbs":-5,"protein":1e999,"fat":2}]');

  assert.equal(item.carbs, null);
  assert.equal(item.protein, null);
  assert.equal(item.fat, 2);
});

test("the prompt lets the model say a carb value is unknown", async () => {
  let body;
  const fetchImpl = async (_url, init) => {
    body = JSON.parse(init.body);
    return completion('[{"name":"Apple","carbs":25}]');
  };

  await lookupFoods("an apple", "key", { fetchImpl, sleep: noSleep });

  const system = body.messages.find((m) => m.role === "system").content;
  assert.match(system, /set "carbs" to null/);
  assert.match(system, /Never estimate or guess/);
  assert.doesNotMatch(system, /never refuse/i);
});

test("splitUnknownCarbs separates foods with no carb value from the rest", () => {
  const { known, unknownNames } = splitUnknownCarbs([
    { name: "Burger", carbs: 30 },
    { name: "Fries", carbs: null },
    { name: "Water", carbs: 0 },
  ]);

  assert.deepEqual(known.map((i) => i.name), ["Burger", "Water"]);
  assert.deepEqual(unknownNames, ["Fries"]);
});

test("listNames joins names the way a sentence would", () => {
  assert.equal(listNames(["fries"]), "fries");
  assert.equal(listNames(["fries", "shake"]), "fries and shake");
  assert.equal(listNames(["fries", "shake", "cake"]), "fries, shake and cake");
});

// ── Logging (health data must not reach Cloud Logging) ──

/** Captures every console line written while [run] executes. */
async function captureLogs(run) {
  const lines = [];
  const originals = { log: console.log, error: console.error, warn: console.warn };
  for (const level of Object.keys(originals)) {
    console[level] = (...args) => lines.push(args.map(String).join(" "));
  }
  try {
    await run();
  } finally {
    Object.assign(console, originals);
  }
  return lines;
}

test("lookupFoods never logs the food text or the model's output", async () => {
  const lines = await captureLogs(async () => {
    // A successful lookup.
    await lookupFoods("secret mystery stew", "key", {
      fetchImpl: stubFetch(completion(
        '[{"name":"Zanzibar pudding","carbs":null,"details":"PRIVATE-DETAIL"}]'
      )),
      sleep: noSleep,
    });
    // Output that never parses, on every attempt.
    await lookupFoods("secret mystery stew", "key", {
      fetchImpl: stubFetch(completion("PRIVATE-GARBAGE with no array")),
      sleep: noSleep,
    }).catch(() => {});
    // A malformed API response.
    const malformed = {
      status: 200, ok: true,
      json: async () => ({ choices: [], note: "PRIVATE-STRUCT" }),
      text: async () => "",
    };
    await lookupFoods("secret mystery stew", "key", {
      fetchImpl: stubFetch(malformed), sleep: noSleep,
    }).catch(() => {});
  });

  assert.ok(lines.length > 0, "expected some logging to inspect");
  for (const line of lines) {
    assert.doesNotMatch(line, /mystery stew|Zanzibar|PRIVATE/, `leaked: ${line}`);
  }
});
```


In `functions/test/handlers.test.js`:

**Edit 1 of 1 — replace:**

```js
  const { deps } = makeDeps();
  await assert.rejects(
    createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c", expectedProductId: "x" } }),
    (err) => err.code === "invalid-argument"
  );
});
```

**with:**

```js
  const { deps } = makeDeps();
  await assert.rejects(
    createHandlers(deps).validateAppStoreReceipt({ auth, data: { receiptData: "a.b.c", expectedProductId: "x" } }),
    (err) => err.code === "invalid-argument"
  );
});

// ── Unknown carb values (review #12) ──

const burgerAndUnknownFries = async () => ({
  items: [{ name: "Burger", carbs: 30 }, { name: "Fries", carbs: null }],
  citations: [],
});

test("a client that accepts unknown carbs gets them as null", async () => {
  const { deps } = makeDeps({ lookupFoods: burgerAndUnknownFries });
  const { getMultipleCarbCounts } = createHandlers(deps);

  const res = await getMultipleCarbCounts({
    auth, data: { input: "burger and fries", acceptsUnknownCarbs: true },
  });

  assert.deepEqual(res.items.map((i) => [i.name, i.carbs]), [["Burger", 30], ["Fries", null]]);
});

test("an older client never sees a null: foods with unknown carbs are dropped", async () => {
  // Those builds turn null into 0 g, which is the bug being fixed.
  const { deps } = makeDeps({ lookupFoods: burgerAndUnknownFries });
  const { getMultipleCarbCounts } = createHandlers(deps);

  const res = await getMultipleCarbCounts({ auth, data: { input: "burger and fries" } });

  assert.deepEqual(res.items.map((i) => i.name), ["Burger"]);
});

test("an older client gets a named error when nothing was found, and it still counts", async () => {
  const { deps, calls } = makeDeps({
    lookupFoods: async () => ({
      items: [{ name: "Fries", carbs: null }, { name: "Shake", carbs: null }],
      citations: [],
    }),
  });
  const { getMultipleCarbCounts } = createHandlers(deps);

  await assert.rejects(
    getMultipleCarbCounts({ auth, data: { input: "fries and shake" } }),
    (err) => {
      assert.equal(err.code, "not-found");
      assert.equal(err.message, "Couldn't find carbs for Fries and Shake.");
      return true;
    }
  );
  // Perplexity billed the call, so the lookup is not given back.
  assert.equal(calls.some(([kind]) => kind === "release"), false);
});
```


- [ ] **Step 2: Run them and watch them fail**

Run: `cd functions && npm test`
Expected: 8 failures:
- `lookupFoods keeps a missing carb value as null, never 0`
- `lookupFoods treats negative and infinite numbers as no value`
- `the prompt lets the model say a carb value is unknown`
- `splitUnknownCarbs …`
- `listNames …`
- `lookupFoods never logs the food text or the model's output`
- `an older client never sees a null …`
- `an older client gets a named error …`

Two of the new tests pass already, and should: `lookupFoods keeps a real zero as zero` (the old code never broke zeros) and `a client that accepts unknown carbs gets them as null` (the old handler passed items through).

- [ ] **Step 3: Change the prompt, parsing and logging**

In `functions/src/perplexity.js`:

**Edit 1 of 6 — replace:**

```js
 * @param {string} sanitized - output of sanitizeFoodInput
 * @param {string} apiKey - Perplexity API key
 * @param {{fetchImpl?: typeof fetch, sleep?: (ms: number) => Promise<void>}} [options] - injectable for tests
 * @returns {Promise<{items: object[], citations: string[]}>}
 */
async function lookupFoods(sanitized, apiKey, { fetchImpl = fetch, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  console.log(`Looking up: "${sanitized}"`);

  const maxAttempts = 3;
  // True once any attempt got a 2xx response, i.e. Perplexity billed us.
  let billed = false;
  const unbilled = (err) => (billed ? err : notBilled(err));
```

**with:**

```js
 * @param {string} sanitized - output of sanitizeFoodInput
 * @param {string} apiKey - Perplexity API key
 * @param {{fetchImpl?: typeof fetch, sleep?: (ms: number) => Promise<void>}} [options] - injectable for tests
 * @returns {Promise<{items: object[], citations: string[]}>}
 */
async function lookupFoods(sanitized, apiKey, { fetchImpl = fetch, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  // Never the food text itself: what someone eats is health data, and this
  // lands in Cloud Logging.
  console.log(`Looking up ${sanitized.length} chars`);

  const maxAttempts = 3;
  // True once any attempt got a 2xx response, i.e. Perplexity billed us.
  let billed = false;
  const unbilled = (err) => (billed ? err : notBilled(err));
```

**Edit 2 of 6 — replace:**

```js
                  "For example, 'heb fajita tortilla' means a fajita-style tortilla sold by the brand HEB — NOT a fajita, NOT a taco. " +
                  "Parse the EXACT product the user is describing before looking up nutrition data. " +
                  "IMPORTANT: Return exactly ONE result per distinct food item the user mentions. " +
                  "If the user says 'tortilla', return only the single best match — do NOT return multiple varieties or sizes. " +
                  "Only return multiple items if the user explicitly lists multiple foods (e.g. 'burger and fries' = 2 items). " +
                  "Respond with ONLY a valid JSON array — no markdown, no code fences, no extra text. " +
                  'Each element must have "name" (string, the full product name including brand if given), "carbs" (number, grams of carbohydrates), ' +
                  '"protein" (number, grams of protein), "fat" (number, grams of total fat), "fiber" (number, grams of dietary fiber), ' +
                  '"calories" (number, kcal), and "details" (string, cite the specific source and serving size). ' +
                  "All numeric fields must be plain numbers — no units, no strings. " +
                  "Priority for data sources: " +
                  "1. Official manufacturer/restaurant/store-brand nutrition info (product packaging, website). " +
                  "2. USDA FoodData Central. " +
                  "3. Reliable nutrition databases (Nutritionix, CalorieKing, MyFitnessPal verified entries). " +
                  "If the exact brand product cannot be found, use the closest matching generic version and note this in details. " +
                  "Always include the serving size in details. " +
                  "You MUST always return a valid JSON array with at least one item — never refuse or return empty results. " +
                  'Example: [{"name":"HEB Fajita Tortilla","carbs":26,"protein":4,"fat":3,"fiber":1,"calories":150,"details":"Per HEB product nutrition label, one fajita-size flour tortilla (1 tortilla, 45g serving)."}]',
              },
              {
                role: "user",
                content: sanitized,
              },
```

**with:**

```js
                  "For example, 'heb fajita tortilla' means a fajita-style tortilla sold by the brand HEB — NOT a fajita, NOT a taco. " +
                  "Parse the EXACT product the user is describing before looking up nutrition data. " +
                  "IMPORTANT: Return exactly ONE result per distinct food item the user mentions. " +
                  "If the user says 'tortilla', return only the single best match — do NOT return multiple varieties or sizes. " +
                  "Only return multiple items if the user explicitly lists multiple foods (e.g. 'burger and fries' = 2 items). " +
                  "Respond with ONLY a valid JSON array — no markdown, no code fences, no extra text. " +
                  'Each element must have "name" (string, the full product name including brand if given), "carbs" (number, grams of carbohydrates, or null — see below), ' +
                  '"protein" (number, grams of protein), "fat" (number, grams of total fat), "fiber" (number, grams of dietary fiber), ' +
                  '"calories" (number, kcal), and "details" (string, cite the specific source and serving size). ' +
                  "All numeric fields must be plain numbers — no units, no strings. " +
                  "Priority for data sources: " +
                  "1. Official manufacturer/restaurant/store-brand nutrition info (product packaging, website). " +
                  "2. USDA FoodData Central. " +
                  "3. Reliable nutrition databases (Nutritionix, CalorieKing, MyFitnessPal verified entries). " +
                  "If the exact brand product cannot be found, use the closest matching generic version and note this in details. " +
                  "Always include the serving size in details. " +
                  "Return one element for every food the user mentions. " +
                  "If you cannot find a reliable carbohydrate value for a food, still return it, but set \"carbs\" to null " +
                  "and say in details why no reliable value was found. Never estimate or guess a carbohydrate value you cannot source: " +
                  "people use these numbers to dose insulin, and a wrong number is worse than none. " +
                  "A food that genuinely has no carbohydrates (water, black coffee) is 0, not null. " +
                  'Example: [{"name":"HEB Fajita Tortilla","carbs":26,"protein":4,"fat":3,"fiber":1,"calories":150,"details":"Per HEB product nutrition label, one fajita-size flour tortilla (1 tortilla, 45g serving)."}]',
              },
              {
                role: "user",
                content: sanitized,
              },
```

**Edit 3 of 6 — replace:**

```js
      }
      billed = true;

      const result = await response.json();

      if (!result.choices || !result.choices[0]) {
        console.error("Invalid API response structure:", JSON.stringify(result).substring(0, 500));
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Invalid API response");
      }

      const rawContent = result.choices[0].message?.content;
      if (typeof rawContent !== "string") {
        console.error("Invalid API response structure:", JSON.stringify(result).substring(0, 500));
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Invalid API response");
      }
```

**with:**

```js
      }
      billed = true;

      const result = await response.json();

      if (!result.choices || !result.choices[0]) {
        console.error(`Invalid API response structure, top-level keys: ${Object.keys(result || {}).join(",")}`);
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Invalid API response");
      }

      const rawContent = result.choices[0].message?.content;
      if (typeof rawContent !== "string") {
        console.error(`Invalid API response structure, top-level keys: ${Object.keys(result || {}).join(",")}`);
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Invalid API response");
      }
```

**Edit 4 of 6 — replace:**

```js
        );
      };

      let content = rawContent.trim();
      const citations = result.citations || [];

      console.log("Raw API response content:", content);

      // Strip markdown code fences if present
      content = content.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();

      // Parse JSON array from response
      const arrayMatch = content.match(/\[[\s\S]*\]/);
      if (!arrayMatch) {
        console.error(`Could not find JSON array (attempt ${attempt}/${maxAttempts}):`, content);
        if (truncated) throw tooManyFoods();
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Could not parse food items");
      }

      let items;
      try {
        items = JSON.parse(arrayMatch[0]);
      } catch (parseErr) {
        console.error(`JSON parse error (attempt ${attempt}/${maxAttempts}):`, parseErr.message, "Content:", arrayMatch[0]);
        if (truncated) throw tooManyFoods();
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Could not parse food items");
      }
      // Drop nulls and other non-objects so the mapping below can't throw on them.
      items = items.filter((item) => item !== null && typeof item === "object");

      if (!Array.isArray(items) || items.length === 0) {
        console.error(`Empty result array (attempt ${attempt}/${maxAttempts}):`, JSON.stringify(items));
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "No food items found in response");
      }
```

**with:**

```js
        );
      };

      let content = rawContent.trim();
      const citations = result.citations || [];

      console.log(`Response: ${content.length} chars, finish_reason=${result.choices[0].finish_reason}`);

      // Strip markdown code fences if present
      content = content.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();

      // Parse JSON array from response
      const arrayMatch = content.match(/\[[\s\S]*\]/);
      if (!arrayMatch) {
        console.error(`Could not find JSON array (attempt ${attempt}/${maxAttempts}) in ${content.length} chars`);
        if (truncated) throw tooManyFoods();
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Could not parse food items");
      }

      let items;
      try {
        items = JSON.parse(arrayMatch[0]);
      } catch (parseErr) {
        console.error(`JSON parse error (attempt ${attempt}/${maxAttempts}): ${parseErr.message}`);
        if (truncated) throw tooManyFoods();
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Could not parse food items");
      }
      // Drop nulls and other non-objects so the mapping below can't throw on them.
      items = items.filter((item) => item !== null && typeof item === "object");

      if (!Array.isArray(items) || items.length === 0) {
        console.error(`Empty result array (attempt ${attempt}/${maxAttempts})`);
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "No food items found in response");
      }
```

**Edit 5 of 6 — replace:**

```js
      const mapped = items.map((item) => {
        const parseNum = (val) => {
          if (typeof val === "string") {
            const m = val.match(/(\d+\.?\d*)/);
            val = m ? parseFloat(m[1]) : null;
          }
          return typeof val === "number" && !isNaN(val) ? val : null;
        };

        const carbs = parseNum(item.carbs) ?? 0;

        return {
          name: String(item.name || "Unknown"),
          carbs: carbs,
          protein: parseNum(item.protein),
          fat: parseNum(item.fat),
          fiber: parseNum(item.fiber),
          calories: parseNum(item.calories),
          details: item.details ? String(item.details) : null,
        };
      });

      console.log(`Returning ${mapped.length} item(s):`, JSON.stringify(mapped));

      return {
        items: mapped,
        citations: citations,
      };
    } catch (error) {
```

**with:**

```js
      const mapped = items.map((item) => {
        const parseNum = (val) => {
          if (typeof val === "string") {
            const m = val.match(/(\d+\.?\d*)/);
            val = m ? parseFloat(m[1]) : null;
          }
          // Negative, infinite or NaN is not a nutrition value.
          return Number.isFinite(val) && val >= 0 ? val : null;
        };

        return {
          name: String(item.name || "Unknown"),
          // null when the model had no reliable value. Never defaulted to 0:
          // a confident 0 g is worse than no answer for someone dosing insulin.
          carbs: parseNum(item.carbs),
          protein: parseNum(item.protein),
          fat: parseNum(item.fat),
          fiber: parseNum(item.fiber),
          calories: parseNum(item.calories),
          details: item.details ? String(item.details) : null,
        };
      });

      const unknown = mapped.filter((item) => item.carbs === null).length;
      console.log(`Returning ${mapped.length} item(s), ${unknown} without carbs`);

      return {
        items: mapped,
        citations: citations,
      };
    } catch (error) {
```

**Edit 6 of 6 — replace:**

```js

      throw unbilled(new HttpsError("internal", error.message));
    }
  }
}

module.exports = { sanitizeFoodInput, lookupFoods, notBilled, isNotBilled };
```

**with:**

```js

      throw unbilled(new HttpsError("internal", error.message));
    }
  }
}

/**
 * Splits looked-up foods into those with a carb value and the names of those
 * without one. Only a missing value counts as unknown; a real 0 stays a food.
 *
 * @param {{name: string, carbs: number|null}[]} items
 * @returns {{known: object[], unknownNames: string[]}}
 */
function splitUnknownCarbs(items) {
  const known = [];
  const unknownNames = [];
  for (const item of items) {
    if (item.carbs === null) unknownNames.push(item.name);
    else known.push(item);
  }
  return { known, unknownNames };
}

/**
 * Joins names the way a sentence would: "fries", "fries and shake",
 * "fries, shake and cake".
 *
 * @param {string[]} names
 * @returns {string}
 */
function listNames(names) {
  if (names.length <= 1) return names.join("");
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
}

module.exports = { sanitizeFoodInput, lookupFoods, notBilled, isNotBilled, splitUnknownCarbs, listNames };
```


- [ ] **Step 4: Filter for older clients**

In `functions/src/handlers.js`:

**Edit 1 of 3 — replace:**

```js
const { HttpsError } = require("firebase-functions/v2/https");
const { sanitizeFoodInput, isNotBilled } = require("./perplexity");
const { parseTzOffset } = require("./quota");
const { PREMIUM_PRODUCT_IDS, isActiveTransaction } = require("./appStore");

/**
 * Builds the callable handlers from injected dependencies so they can be
 * tested without Firestore, Apple, or Perplexity.
```

**with:**

```js
const { HttpsError } = require("firebase-functions/v2/https");
const { sanitizeFoodInput, isNotBilled, splitUnknownCarbs, listNames } = require("./perplexity");
const { parseTzOffset } = require("./quota");
const { PREMIUM_PRODUCT_IDS, isActiveTransaction } = require("./appStore");

/**
 * Builds the callable handlers from injected dependencies so they can be
 * tested without Firestore, Apple, or Perplexity.
```

**Edit 2 of 3 — replace:**

```js
    // 20 carb lookups per minute per user
    await deps.checkRateLimit(uid, "getCarbCounts", 20, 60);

    const data = request.data || {};
    const sanitized = sanitizeFoodInput(data.input);
    const tzOffsetMin = parseTzOffset(data.tzOffsetMinutes);

    // Fail closed: if premium status or the quota can't be checked, don't
    // spend a Perplexity call.
    let premium;
    let reservation = null;
    try {
```

**with:**

```js
    // 20 carb lookups per minute per user
    await deps.checkRateLimit(uid, "getCarbCounts", 20, 60);

    const data = request.data || {};
    const sanitized = sanitizeFoodInput(data.input);
    const tzOffsetMin = parseTzOffset(data.tzOffsetMinutes);
    // Sent by builds that know a food can come back with no carb value.
    const acceptsUnknownCarbs = data.acceptsUnknownCarbs === true;

    // Fail closed: if premium status or the quota can't be checked, don't
    // spend a Perplexity call.
    let premium;
    let reservation = null;
    try {
```

**Edit 3 of 3 — replace:**

```js
          console.error(`[quota] Release failed for ${uid}: ${releaseErr.message}`);
        }
      }
      throw err;
    }

    return {
      items: result.items,
      citations: result.citations,
      quota: premium
        ? { premium: true, used: null, limit: null, dayKey: null }
        : { premium: false, used: reservation.used, limit: reservation.limit, dayKey: reservation.dayKey },
    };
  }
```

**with:**

```js
          console.error(`[quota] Release failed for ${uid}: ${releaseErr.message}`);
        }
      }
      throw err;
    }

    // Older builds turn a missing carb value into 0 g, the very bug this
    // replaces, so they never see one: they get the foods that were found, or
    // an error naming the ones that weren't. Thrown after the lookup, outside
    // the refund above, so it counts like any other call Perplexity billed.
    let items = result.items;
    if (!acceptsUnknownCarbs) {
      const { known, unknownNames } = splitUnknownCarbs(items);
      if (known.length === 0) {
        throw new HttpsError("not-found", `Couldn't find carbs for ${listNames(unknownNames)}.`);
      }
      items = known;
    }

    return {
      items,
      citations: result.citations,
      quota: premium
        ? { premium: true, used: null, limit: null, dayKey: null }
        : { premium: false, used: reservation.used, limit: reservation.limit, dayKey: reservation.dayKey },
    };
  }
```


- [ ] **Step 5: Run the tests**

Run: `cd functions && npm test`
Expected: `ℹ tests 91`, `ℹ pass 91`, `ℹ fail 0`.

- [ ] **Step 6: Commit**

```bash
git add functions/src/perplexity.js functions/src/handlers.js functions/test/perplexity.test.js functions/test/handlers.test.js
git commit -m "fix(lookup): say when carbs are unknown instead of inventing 0 g"
```

---

### Task 2: Dart lookup parsing — unknown carbs stay out of `FoodItem`

**Files:**
- Modify: `lib/services/lookup_api.dart`
- Test: `test/lookup_api_test.dart`

**Interfaces:**
- Consumes: the server contract from Task 1 (`carbs` may be `null`).
- Produces: `LookupResult({required List<FoodItem> items, List<String> unknownCarbs = const [], ServerQuota? quota})` and `parseLookupResponse(String body, {DateTime? now})`. Foods from one lookup get `loggedAt = now + i ms`.

- [ ] **Step 1: Write the failing tests**

In `test/lookup_api_test.dart`:

**Edit 1 of 1 — replace:**

```dart
          throwsA(isA<UserFacingException>()));
      expect(() => parseLookupResponse('{}'), throwsA(isA<UserFacingException>()));
      expect(() => parseLookupResponse('not json'), throwsA(isA<UserFacingException>()));
    });
  });

  group('parseCallableError', () {
    test('daily-quota 429 becomes DailyLimitReachedException', () {
      final e = parseCallableError(
        429,
        callableError('RESOURCE_EXHAUSTED', "You've used today's 4 free lookups.",
            {'reason': 'daily-quota', 'used': 4, 'limit': 4, 'dayKey': '2026-09-18'}),
```

**with:**

```dart
          throwsA(isA<UserFacingException>()));
      expect(() => parseLookupResponse('{}'), throwsA(isA<UserFacingException>()));
      expect(() => parseLookupResponse('not json'), throwsA(isA<UserFacingException>()));
    });
  });

  group('unknown carb values', () {
    LookupResult parse(List<Map<String, dynamic>> items, {DateTime? now}) =>
        parseLookupResponse(callableResult({'items': items}), now: now);

    test('a food with no carb value is reported by name, never as 0 g', () {
      final result = parse([
        {'name': 'Burger', 'carbs': 30},
        {'name': 'Fries', 'carbs': null},
      ]);

      expect(result.items.map((f) => f.name), ['Burger']);
      expect(result.unknownCarbs, ['Fries']);
    });

    test('a real zero is a food, not an unknown', () {
      final result = parse([
        {'name': 'Water', 'carbs': 0},
      ]);

      expect(result.items.single.carbs, 0.0);
      expect(result.unknownCarbs, isEmpty);
    });

    test('negative and unreadable values count as unknown', () {
      final result = parse([
        {'name': 'Odd', 'carbs': -5},
        {'name': 'Vague', 'carbs': 'some'},
      ]);

      expect(result.items, isEmpty);
      expect(result.unknownCarbs, ['Odd', 'Vague']);
    });

    test('a lookup where nothing had carbs still parses, for the hand-off', () {
      final result = parse([
        {'name': 'Fries', 'carbs': null},
      ]);

      expect(result.items, isEmpty);
      expect(result.unknownCarbs, ['Fries']);
    });
  });

  group('logging times', () {
    test('foods from one lookup start 1 ms apart', () {
      // So deleting one from Apple Health can't take the others with it.
      final now = DateTime(2026, 9, 22, 12, 30);
      final result = parseLookupResponse(
        callableResult({
          'items': [
            {'name': 'Burger', 'carbs': 30},
            {'name': 'Fries', 'carbs': null},
            {'name': 'Shake', 'carbs': 60},
          ],
        }),
        now: now,
      );

      expect(result.items.map((f) => f.loggedAt), [
        now,
        now.add(const Duration(milliseconds: 1)),
      ]);
    });
  });

  group('parseCallableError', () {
    test('daily-quota 429 becomes DailyLimitReachedException', () {
      final e = parseCallableError(
        429,
        callableError('RESOURCE_EXHAUSTED', "You've used today's 4 free lookups.",
            {'reason': 'daily-quota', 'used': 4, 'limit': 4, 'dayKey': '2026-09-18'}),
```


- [ ] **Step 2: Run them and watch them fail**

Run: `flutter test test/lookup_api_test.dart`
Expected: compile errors, `No named parameter with the name 'now'` and `The getter 'unknownCarbs' isn't defined for the type 'LookupResult'`.

- [ ] **Step 3: Parse unknown carbs and space the foods**

In `lib/services/lookup_api.dart`:

**Edit 1 of 2 — replace:**

```dart
import '../models/food_item.dart';
import '../models/server_quota.dart';
import '../utils/user_facing_exception.dart';

/// Result of one getMultipleCarbCounts call.
class LookupResult {
  const LookupResult({required this.items, this.quota});

  final List<FoodItem> items;

  /// Null when the server response has no `quota` (older deployment).
  final ServerQuota? quota;
}

/// Parses a 200 response body from the getMultipleCarbCounts callable.
/// Throws [UserFacingException] when the body has no usable items.
LookupResult parseLookupResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw const UserFacingException('No results returned. Please try again.');
  }
```

**with:**

```dart
import '../models/food_item.dart';
import '../models/server_quota.dart';
import '../utils/user_facing_exception.dart';

/// Result of one getMultipleCarbCounts call.
class LookupResult {
  const LookupResult({
    required this.items,
    this.unknownCarbs = const [],
    this.quota,
  });

  /// The foods the lookup found a carb value for, ready to log.
  final List<FoodItem> items;

  /// Names of foods the lookup couldn't find a reliable carb value for. They
  /// never become [FoodItem]s — a FoodItem always has a number, so nothing
  /// downstream can count an unknown as 0 g. The app hands them to Manual
  /// entry instead.
  final List<String> unknownCarbs;

  /// Null when the server response has no `quota` (older deployment).
  final ServerQuota? quota;
}

/// Parses a 200 response body from the getMultipleCarbCounts callable.
/// Throws [UserFacingException] when the body has no usable items.
///
/// [now] is when the foods are logged; tests pass a fixed time.
LookupResult parseLookupResponse(String body, {DateTime? now}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw const UserFacingException('No results returned. Please try again.');
  }
```

**Edit 2 of 2 — replace:**

```dart
  double? parseOptional(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  final foods = items.whereType<Map>().map((item) {
    final carbsRaw = item['carbs'];
    final carbs = carbsRaw is num
        ? carbsRaw.toDouble()
        : double.tryParse(carbsRaw.toString()) ?? 0.0;

    return FoodItem(
      name: (item['name'] as String?) ?? 'Unknown',
      carbs: carbs,
      protein: parseOptional(item['protein']),
      fat: parseOptional(item['fat']),
      fiber: parseOptional(item['fiber']),
      calories: parseOptional(item['calories']),
      details: item['details'] as String?,
      citations: citations,
    );
  }).toList();

  return LookupResult(items: foods, quota: ServerQuota.fromJson(result['quota']));
}

/// Maps a non-200 callable response to the exception the UI should show.
/// Callable errors have the body `{"error": {"message", "status", "details"}}`.
UserFacingException parseCallableError(int statusCode, String body) {
  Map? error;
```

**with:**

```dart
  double? parseOptional(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  // A missing, unreadable, negative or infinite value means the lookup has no
  // carb number for this food. It is never read as 0: a confident 0 g is worse
  // than no answer for someone dosing insulin.
  double? parseCarbs(dynamic v) {
    final value = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    return value != null && value.isFinite && value >= 0 ? value : null;
  }

  final base = now ?? DateTime.now();
  final foods = <FoodItem>[];
  final unknownCarbs = <String>[];
  for (final item in items.whereType<Map>()) {
    final name = (item['name'] as String?) ?? 'Unknown';
    final carbs = parseCarbs(item['carbs']);
    if (carbs == null) {
      unknownCarbs.add(name);
      continue;
    }
    foods.add(FoodItem(
      name: name,
      carbs: carbs,
      protein: parseOptional(item['protein']),
      fat: parseOptional(item['fat']),
      fiber: parseOptional(item['fiber']),
      calories: parseOptional(item['calories']),
      details: item['details'] as String?,
      citations: citations,
      // Each food from one lookup starts in its own millisecond, so deleting
      // one from Apple Health can't take the others with it: the delete
      // matches a single millisecond (HealthKitService.deleteFoodItem).
      loggedAt: base.add(Duration(milliseconds: foods.length)),
    ));
  }

  if (foods.isEmpty && unknownCarbs.isEmpty) {
    throw const UserFacingException(
        'No food items found. Please try a different description.');
  }

  return LookupResult(
    items: foods,
    unknownCarbs: unknownCarbs,
    quota: ServerQuota.fromJson(result['quota']),
  );
}

/// Maps a non-200 callable response to the exception the UI should show.
/// Callable errors have the body `{"error": {"message", "status", "details"}}`.
UserFacingException parseCallableError(int statusCode, String body) {
  Map? error;
```


- [ ] **Step 4: Run the tests**

Run: `flutter test test/lookup_api_test.dart`, then `flutter analyze && flutter test`
Expected: `+13: All tests passed!` for the file, `No issues found!`, and the full suite green (141).

Don't send `acceptsUnknownCarbs` yet. Task 4 adds it together with the hand-off that uses `unknownCarbs`. Until then a flagged build would silently drop unknown foods.

- [ ] **Step 5: Commit**

```bash
git add lib/services/lookup_api.dart test/lookup_api_test.dart
git commit -m "fix(lookup): keep foods with no carb value out of FoodItem"
```

---

### Task 3: Delete exactly one food from Apple Health

**Files:**
- Modify: `lib/services/health_kit_service.dart`
- Create: `test/health_kit_service_test.dart`

**Interfaces:**
- Consumes: foods 1 ms apart (Task 2 for lookups; Task 5 for Siri).
- Produces: top-level `({DateTime start, DateTime end}) healthDeleteWindow(DateTime loggedAt)`.

Why this works: the plugin's delete matches this app's own entries by start time only, via HealthKit's `.strictStartDate`. That was checked on this Mac: it compiles to `startDate >= start AND startDate < end`, so the end is exclusive. A 1 ms window can't catch a food started exactly 1 ms later.

- [ ] **Step 1: Write the failing test**

Create `test/health_kit_service_test.dart`:

```dart
import 'package:carb_tracker/services/health_kit_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('healthDeleteWindow', () {
    test('covers exactly the millisecond the food started in', () {
      // Half a millisecond in: the plugin passes whole milliseconds to
      // HealthKit, so the window must line up with what the write stored.
      final loggedAt = DateTime.fromMicrosecondsSinceEpoch(1758542400000500);

      final window = healthDeleteWindow(loggedAt);

      expect(window.start.millisecondsSinceEpoch, 1758542400000);
      expect(window.end.millisecondsSinceEpoch, 1758542400001);
    });

    test('leaves out a food from the same lookup, logged 1 ms later', () {
      final burger = DateTime(2026, 9, 22, 12, 30);
      final fries = burger.add(const Duration(milliseconds: 1));

      final window = healthDeleteWindow(burger);

      // HealthKit's strict-start window: start inclusive, end exclusive.
      bool startsIn(DateTime t) =>
          !t.isBefore(window.start) && t.isBefore(window.end);
      expect(startsIn(burger), isTrue);
      expect(startsIn(fries), isFalse,
          reason: 'the one-minute window this replaces deleted fries too');
    });
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/health_kit_service_test.dart`
Expected: compile error, `Method not found: 'healthDeleteWindow'`.

- [ ] **Step 3: Narrow the delete**

In `lib/services/health_kit_service.dart`:

**Edit 1 of 2 — replace:**

```dart
    } catch (e) {
      debugPrint('HealthKit: writeFoodItem failed for "${item.name}": $e');
      return false;
    }
  }

  /// Delete a food item from HealthKit by matching its exact timestamp.
  Future<bool> deleteFoodItem(FoodItem item) async {
    if (!Platform.isIOS || !_isAuthorized) return false;

    try {
      final success = await _health.delete(
        type: HealthDataType.NUTRITION,
        startTime: item.loggedAt,
        endTime: item.loggedAt.add(const Duration(minutes: 1)),
      );
      return success;
    } catch (e) {
      debugPrint('HealthKit: deleteFoodItem failed for "${item.name}": $e');
      return false;
    }
```

**with:**

```dart
    } catch (e) {
      debugPrint('HealthKit: writeFoodItem failed for "${item.name}": $e');
      return false;
    }
  }

  /// Delete a food item from HealthKit: only the entry that starts in the
  /// millisecond [item] was logged (see [healthDeleteWindow]).
  Future<bool> deleteFoodItem(FoodItem item) async {
    if (!Platform.isIOS || !_isAuthorized) return false;

    try {
      final window = healthDeleteWindow(item.loggedAt);
      final success = await _health.delete(
        type: HealthDataType.NUTRITION,
        startTime: window.start,
        endTime: window.end,
      );
      return success;
    } catch (e) {
      debugPrint('HealthKit: deleteFoodItem failed for "${item.name}": $e');
      return false;
    }
```

**Edit 2 of 2 — replace:**

```dart
      grouped[date]!.add(entry);
    }

    return grouped;
  }
}
```

**with:**

```dart
      grouped[date]!.add(entry);
    }

    return grouped;
  }
}

/// The time range a delete searches for the Health entry of a food logged at
/// [loggedAt]: exactly the millisecond it starts in.
///
/// The plugin's delete matches this app's own entries by start time only, and
/// the end is exclusive (HealthKit's `.strictStartDate` is `startDate >= start
/// AND startDate < end`). Every entry the app writes starts in its own
/// millisecond — foods from one lookup or one Siri log are spaced 1 ms apart —
/// so this matches one entry. The one-minute range it replaces took every food
/// logged in that minute, including the rest of a "burger and fries".
({DateTime start, DateTime end}) healthDeleteWindow(DateTime loggedAt) {
  // Whole milliseconds, which is what the plugin passes to HealthKit for both
  // the write and the delete, so the two agree.
  final start =
      DateTime.fromMillisecondsSinceEpoch(loggedAt.millisecondsSinceEpoch);
  return (start: start, end: start.add(const Duration(milliseconds: 1)));
}
```


- [ ] **Step 4: Run the tests**

Run: `flutter test test/health_kit_service_test.dart`, then `flutter analyze && flutter test`
Expected: `+2: All tests passed!`, `No issues found!`, full suite green (143).

- [ ] **Step 5: Commit**

```bash
git add lib/services/health_kit_service.dart test/health_kit_service_test.dart
git commit -m "fix(health): delete only the entry that starts in the food's millisecond"
```

---

### Task 4: App — hand unknown foods to Manual entry

**Files:**
- Modify: `lib/main.dart`, `lib/services/perplexity_firebase_service.dart`
- Test: `test/widget_test.dart`

**Interfaces:**
- Consumes: `LookupResult.unknownCarbs` (Task 2).
- Produces: `_applyLookupResult(LookupResult)`, `_handOffUnknownCarbs(List<String>)`, and the test hook `applyLookupResultForTest(LookupResult)` next to the existing `resetTotalForTest`.

Manual entry is open to every user: `PremiumService.isManualEntryEnabled` returns `true`. If that ever becomes Premium-only, the hand-off needs another way out. The code comment says so.

Three widget-test traps the tests below already avoid (don't undo them):
- Logging a food saves and pushes to iCloud, and an unstubbed platform channel never answers in a widget test, so the tests call `stubCloudSync()`.
- Awaiting app work without pumping frames stalls, so the helper pumps while it waits.
- The hand-off focuses the carb field, and its blinking cursor means `pumpAndSettle` never returns, so the helper pumps a bounded number of frames instead.

- [ ] **Step 1: Write the failing tests**

In `test/widget_test.dart`:

**Edit 1 of 2 — replace:**

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';

void main() {
  String keyOf(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  String todayKey() => keyOf(DateTime.now());
```

**with:**

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:carb_tracker/main.dart';
import 'package:carb_tracker/models/food_item.dart';
import 'package:carb_tracker/services/lookup_api.dart';

void main() {
  String keyOf(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  String todayKey() => keyOf(DateTime.now());
```

**Edit 2 of 2 — replace:**

```dart
      await tester.pumpAndSettle();

      expect(state.foodItems.map((f) => f.name), ['Apple']);
      expect(tester.takeException(), isNull);
    });
  });
}
```

**with:**

```dart
      await tester.pumpAndSettle();

      expect(state.foodItems.map((f) => f.name), ['Apple']);
      expect(tester.takeException(), isNull);
    });
  });

  group('unknown carbs', () {
    /// The food-name field: the first TextField on the home screen.
    String foodFieldText(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField).first).controller!.text;

    /// Manual entry shows a second field, for the carb number.
    Finder carbField() => find.byWidgetPredicate((w) =>
        w is TextField &&
        w.keyboardType == const TextInputType.numberWithOptions(decimal: true));

    /// Applies [result] while pumping frames, and returns once it's done.
    ///
    /// Awaiting it without pumping would stall on work that waits for a frame.
    /// pumpAndSettle can't be used either: the hand-off focuses the carb field,
    /// and a focused field's blinking cursor keeps scheduling frames, so it
    /// would never settle. So pump a bounded number of frames instead.
    Future<void> applyLookup(
        WidgetTester tester, CarbTrackerHomeState state, LookupResult result) async {
      var finished = false;
      state.applyLookupResultForTest(result).whenComplete(() => finished = true);
      for (var i = 0; i < 50 && !finished; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(finished, isTrue, reason: 'the lookup result never finished applying');
      // Past the snackbar's entrance animation.
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<CarbTrackerHomeState> pumpHome(WidgetTester tester) async {
      stubHomeWidget();
      // Logging a food saves and pushes to iCloud; an unstubbed channel never
      // answers in a widget test.
      stubCloudSync();
      await tester.pumpWidget(const CarbTrackerApp());
      await tester.pumpAndSettle();
      return tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    }

    testWidgets('a food with no carb value hands off to Manual entry, never 0 g',
        (WidgetTester tester) async {
      final state = await pumpHome(tester);

      await applyLookup(tester, state, LookupResult(
        items: [FoodItem(id: 'b', name: 'Burger', carbs: 30)],
        unknownCarbs: const ['Fries'],
      ));

      expect(state.foodItems.map((f) => f.name), ['Burger']);
      expect(find.text("Couldn't find carbs for Fries \u2014 enter it manually."),
          findsOneWidget);
      expect(foodFieldText(tester), 'Fries');
      expect(carbField(), findsOneWidget);
    });

    testWidgets('when nothing was found, nothing is logged and all are named',
        (WidgetTester tester) async {
      final state = await pumpHome(tester);

      await applyLookup(tester, state, const LookupResult(
        items: [],
        unknownCarbs: ['Fries', 'Shake'],
      ));

      expect(state.foodItems, isEmpty);
      expect(
          find.text(
              "Couldn't find carbs for Fries and Shake \u2014 enter them manually."),
          findsOneWidget);
      expect(foodFieldText(tester), 'Fries');
    });

    testWidgets('a lookup where everything was found stays in lookup mode',
        (WidgetTester tester) async {
      final state = await pumpHome(tester);

      await applyLookup(tester, state, LookupResult(
        items: [FoodItem(id: 'b', name: 'Burger', carbs: 30)],
      ));

      expect(state.foodItems.map((f) => f.name), ['Burger']);
      expect(carbField(), findsNothing);
    });
  });
}
```


- [ ] **Step 2: Run them and watch them fail**

Run: `flutter test test/widget_test.dart --plain-name "unknown carbs"`
Expected: compile error, `The method 'applyLookupResultForTest' isn't defined for the type 'CarbTrackerHomeState'`.

- [ ] **Step 3: Add the hand-off**

In `lib/main.dart`:

**Edit 1 of 4 — replace:**

```dart
import 'package:home_widget/home_widget.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'dart:convert';
import 'dart:io';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_buffer_service.dart';
import 'services/siri_import.dart';
```

**with:**

```dart
import 'package:home_widget/home_widget.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'dart:convert';
import 'dart:io';
import 'services/lookup_api.dart';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_buffer_service.dart';
import 'services/siri_import.dart';
```

**Edit 2 of 4 — replace:**

```dart
    try {
      final result = await _perplexityService.getMultipleCarbCounts(foodText);
      final quota = result.quota;
      if (quota != null) await _premiumService.applyServerQuota(quota);

      if (!mounted) return;

      final items = result.items;

      setState(() {
        isLoading = false;
        showingDailyTotal = false;
        _foodController.clear();
      });

      // Insert one at a time so AnimatedList and foodItems stay in sync
      // and every item gets its own entrance animation
      for (final item in items.reversed) {
        foodItems.insert(0, item);
        _listKey.currentState
            ?.insertItem(0, duration: const Duration(milliseconds: 400));
      }

      HapticFeedback.lightImpact();

      await _saveData();
      await _updateWidget();

      // Write each item to HealthKit
      for (final item in items) {
        _writeToHealthKit(item);
      }
    } on DailyLimitReachedException catch (e) {
      final limit = e.limit ?? _premiumService.dailyLookupLimit;
      await _premiumService.applyServerQuota(ServerQuota(
          premium: false, used: e.used ?? limit, limit: limit, dayKey: e.dayKey));
      if (!mounted) return;
      setState(() {
```

**with:**

```dart
    try {
      final result = await _perplexityService.getMultipleCarbCounts(foodText);
      final quota = result.quota;
      if (quota != null) await _premiumService.applyServerQuota(quota);

      if (!mounted) return;
      await _applyLookupResult(result);
    } on DailyLimitReachedException catch (e) {
      final limit = e.limit ?? _premiumService.dailyLookupLimit;
      await _premiumService.applyServerQuota(ServerQuota(
          premium: false, used: e.used ?? limit, limit: limit, dayKey: e.dayKey));
      if (!mounted) return;
      setState(() {
```

**Edit 3 of 4 — replace:**

```dart
          ),
        );
      }
    }
  }

  void _addManualFood() {
    if (!_premiumService.isManualEntryEnabled) return;
    final name = _foodController.text.trim();
    final carbText = _carbController.text.trim();

    if (name.isEmpty) {
```

**with:**

```dart
          ),
        );
      }
    }
  }

  /// Logs the foods a lookup found and hands any it couldn't find a carb value
  /// for to Manual entry, so they're never logged as a guess.
  Future<void> _applyLookupResult(LookupResult result) async {
    final items = result.items;

    setState(() {
      isLoading = false;
      showingDailyTotal = false;
      _foodController.clear();
    });

    if (items.isNotEmpty) {
      // Insert one at a time so AnimatedList and foodItems stay in sync
      // and every item gets its own entrance animation
      for (final item in items.reversed) {
        foodItems.insert(0, item);
        _listKey.currentState
            ?.insertItem(0, duration: const Duration(milliseconds: 400));
      }

      HapticFeedback.lightImpact();

      await _saveData();
      await _updateWidget();

      // Write each item to HealthKit
      for (final item in items) {
        _writeToHealthKit(item);
      }
    }

    if (result.unknownCarbs.isNotEmpty && mounted) {
      _handOffUnknownCarbs(result.unknownCarbs);
    }
  }

  /// The lookup had no reliable carb value for [names]. Rather than log a
  /// number nobody could source, switch to Manual entry with the first one
  /// filled in so the user types it. Manual entry is open to every user
  /// (PremiumService.isManualEntryEnabled); if that ever changes, this needs
  /// another way out.
  void _handOffUnknownCarbs(List<String> names) {
    setState(() {
      _isManualEntryMode = true;
      _foodController.text = names.first;
      _carbController.clear();
    });
    _carbFocusNode.requestFocus();

    final them = names.length == 1 ? 'it' : 'them';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            "Couldn't find carbs for ${_listNames(names)} \u2014 enter $them manually."),
        backgroundColor: AppColors.honey.withValues(alpha: 0.9),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// "fries", "fries and shake", "fries, shake and cake".
  static String _listNames(List<String> names) => names.length <= 1
      ? names.join()
      : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

  void _addManualFood() {
    if (!_premiumService.isManualEntryEnabled) return;
    final name = _foodController.text.trim();
    final carbText = _carbController.text.trim();

    if (name.isEmpty) {
```

**Edit 4 of 4 — replace:**

```dart
      ),
    );
  }

  // Test hooks — allow tests to drive state without relying on off-screen UI.
  void resetTotalForTest() => _resetTotal();
  void switchToSettingsForTest() => _switchToPage(1);

  void _resetTotal() {
    // Capture items before clearing so animation builders have valid references.
    final snapshot = List<FoodItem>.from(foodItems);
    setState(() {
```

**with:**

```dart
      ),
    );
  }

  // Test hooks — allow tests to drive state without relying on off-screen UI.
  void resetTotalForTest() => _resetTotal();
  Future<void> applyLookupResultForTest(LookupResult result) =>
      _applyLookupResult(result);
  void switchToSettingsForTest() => _switchToPage(1);

  void _resetTotal() {
    // Capture items before clearing so animation builders have valid references.
    final snapshot = List<FoodItem>.from(foodItems);
    setState(() {
```


- [ ] **Step 4: Send the flag**

In `lib/services/perplexity_firebase_service.dart`:

**Edit 1 of 1 — replace:**

```dart

    final body = jsonEncode({
      'data': {
        'input': sanitizedInput,
        // Lets the server count the free quota per local calendar day.
        'tzOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
      }
    });

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 60);
```

**with:**

```dart

    final body = jsonEncode({
      'data': {
        'input': sanitizedInput,
        // Lets the server count the free quota per local calendar day.
        'tzOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
        // This build handles a food with no carb value (LookupResult.
        // unknownCarbs). Without it the server drops such foods, because
        // older builds would have turned the missing value into 0 g.
        'acceptsUnknownCarbs': true,
      }
    });

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 60);
```


- [ ] **Step 5: Run the tests**

Run: `flutter test test/widget_test.dart --plain-name "unknown carbs"`, then `flutter analyze && flutter test`
Expected: `+3: All tests passed!`, `No issues found!`, full suite `+146: All tests passed!`.

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart lib/services/perplexity_firebase_service.dart test/widget_test.dart
git commit -m "fix(lookup): hand foods with unknown carbs to Manual entry"
```

---

### Task 5: Siri — skip unknown foods and keep milliseconds

**Files:**
- Modify: `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift`, `ios/CarbShared/Sources/CarbShared/LogFoodDialog.swift`, `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift`, `ios/Runner/CarbIntents.swift`
- Test: `ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift`, `LogFoodDialogTests.swift`, `CarbDataStoreTests.swift`

**Interfaces:**
- Produces:
  - `LookupResult(items:citations:unknownCarbs: = [])`
  - `LogFoodDialog.text(items:totalToday:skipped: = [])`
  - `@MainActor @discardableResult CarbDataStore.addFoods(_ foods: [LoggedFood], now: Date = Date()) -> Double`, which spaces foods 1 ms apart and returns today's total. The batching lives in `CarbShared` so `swift test` covers it; `LogFoodIntent` only calls it.

One existing test enshrined the bug: `nonFiniteOrNegativeNumbersAreDropped` asserted `carbs: 0` for a `"nan"` value. The edit below replaces it. Another existing test, `addFoodBuffersItemsWithMacrosForTheApp`, pinned the whole-second timestamp format and is updated to expect milliseconds.

- [ ] **Step 1: Write the failing tests**

In `ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift`:

**Edit 1 of 1 — replace:**

```swift
        #expect(result == LookupResult(items: [
            LookupItem(name: "Big Mac", carbs: 45, protein: 25, fat: 30, fiber: 3, calories: 590, details: "McDonald's [1]"),
            LookupItem(name: "Fries", carbs: 48),
        ], citations: ["https://example.com"]))
    }

    @Test func nonFiniteOrNegativeNumbersAreDropped() throws {
        let data = try body([
            "items": [
                ["name": "Mystery", "carbs": "nan", "protein": "inf", "fat": -3],
            ],
        ])
        let result = try PerplexityClient.parseResponse(data)
        #expect(result.items == [LookupItem(name: "Mystery", carbs: 0, protein: nil, fat: nil)])
    }

    @Test func emptyItemsSaysNothingWasFound() throws {
        let data = try body(["items": [] as [Any]])
        #expect(throws: IntentError.self) { try PerplexityClient.parseResponse(data) }
        do {
```

**with:**

```swift
        #expect(result == LookupResult(items: [
            LookupItem(name: "Big Mac", carbs: 45, protein: 25, fat: 30, fiber: 3, calories: 590, details: "McDonald's [1]"),
            LookupItem(name: "Fries", carbs: 48),
        ], citations: ["https://example.com"]))
    }

    @Test func nonFiniteOrNegativeMacrosAreDropped() throws {
        let data = try body([
            "items": [
                ["name": "Mystery", "carbs": 12, "protein": "inf", "fat": -3],
            ],
        ])
        let result = try PerplexityClient.parseResponse(data)
        #expect(result.items == [LookupItem(name: "Mystery", carbs: 12, protein: nil, fat: nil)])
    }

    @Test func aFoodWithNoCarbValueIsSkippedNotZero() throws {
        let data = try body([
            "items": [
                ["name": "Burger", "carbs": 30],
                ["name": "Fries", "carbs": NSNull()],
                ["name": "Mystery", "carbs": "nan"],
            ],
        ])
        let result = try PerplexityClient.parseResponse(data)
        // A confident 0 g is worse than no answer for someone dosing insulin.
        #expect(result.items == [LookupItem(name: "Burger", carbs: 30)])
        #expect(result.unknownCarbs == ["Fries", "Mystery"])
    }

    @Test func aRealZeroIsLogged() throws {
        let data = try body(["items": [["name": "Water", "carbs": 0]]])
        #expect(try PerplexityClient.parseResponse(data).items == [LookupItem(name: "Water", carbs: 0)])
    }

    @Test func noCarbValuesAtAllSaysNothingWasFound() throws {
        let data = try body(["items": [["name": "Fries", "carbs": NSNull()]]])
        do {
            _ = try PerplexityClient.parseResponse(data)
            Issue.record("expected an error")
        } catch let IntentError.message(message) {
            #expect(message == "I couldn't find nutrition info for that.")
        }
    }

    @Test func emptyItemsSaysNothingWasFound() throws {
        let data = try body(["items": [] as [Any]])
        #expect(throws: IntentError.self) { try PerplexityClient.parseResponse(data) }
        do {
```


In `ios/CarbShared/Tests/CarbSharedTests/LogFoodDialogTests.swift`:

**Edit 1 of 1 — replace:**

```swift

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

**with:**

```swift

    @Test func threeItemsAreListed() {
        #expect(LogFoodDialog.text(items: [bigMac, fries, coke], totalToday: 132) ==
            "Logged Big Mac, 45.0 grams, fries, 48.0 grams, and Coke, 39.0 grams: 132.0 grams. Your total today is 132.0 grams.")
    }

    @Test func aSkippedFoodIsNamed() {
        #expect(LogFoodDialog.text(items: [bigMac], totalToday: 88, skipped: ["fries"]) ==
            "Big Mac has 45.0 grams of carbs. Your total today is 88.0 grams. I couldn't find carbs for fries, so I didn't log it.")
    }

    @Test func severalSkippedFoodsAreNamed() {
        #expect(LogFoodDialog.text(items: [bigMac], totalToday: 88, skipped: ["fries", "shake", "pie"]) ==
            "Big Mac has 45.0 grams of carbs. Your total today is 88.0 grams. I couldn't find carbs for fries, shake, and pie, so I didn't log them.")
    }

    @Test func fourOrMoreItemsAreCounted() {
        #expect(LogFoodDialog.text(items: [bigMac, fries, coke, bigMac], totalToday: 177) ==
            "Logged 4 items, 177.0 grams. Your total today is 177.0 grams.")
    }
}
```


In `ios/CarbShared/Tests/CarbSharedTests/CarbDataStoreTests.swift`:

**Edit 1 of 2 — replace:**

```swift
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

    @Test func takeSiriLoggedItemsReturnsTheBufferAndEmptiesIt() {
        store.addFood(LoggedFood(name: "Toast", carbs: 15), now: noon)
```

**with:**

```swift
    @Test func addFoodAddsToTodaysTotal() {
        store.addFood(LoggedFood(name: "Apple", carbs: 25), now: noon)
        store.addFood(LoggedFood(name: "Fries", carbs: 48), now: noon)
        #expect(store.snapshot(now: noon) == CarbSnapshot(totalCarbs: 73, lastFoodName: "Fries", lastFoodCarbs: 48, dailyGoal: nil))
    }

    @Test func addFoodBuffersItemsWithMacrosForTheApp() throws {
        store.addFood(LoggedFood(name: "Big Mac", carbs: 45, protein: 25, fat: 30, fiber: 3, calories: 590,
                                 details: "McDonald's", citations: ["https://example.com"]), now: noon)
        store.addFood(LoggedFood(name: "Water", carbs: 0), now: noon)
        let buffer = store.siriLoggedItems()
        #expect(buffer.count == 2)
        #expect(buffer[0]["name"] as? String == "Big Mac")
        #expect(buffer[0]["protein"] as? Double == 25)
        #expect(buffer[0]["calories"] as? Double == 590)
        #expect(buffer[0]["citations"] as? [String] == ["https://example.com"])
        // The time the food was logged, with milliseconds, so foods from one
        // lookup stay apart.
        let stamp = try #require(buffer[0]["loggedAt"] as? String)
        let withMilliseconds = ISO8601DateFormatter()
        withMilliseconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(withMilliseconds.date(from: stamp) == noon)
        #expect(stamp.hasSuffix(".000Z"))
        #expect(buffer[1]["protein"] == nil)
    }

    @Test func takeSiriLoggedItemsReturnsTheBufferAndEmptiesIt() {
        store.addFood(LoggedFood(name: "Toast", carbs: 15), now: noon)
```

**Edit 2 of 2 — replace:**

```swift
        #expect(store.takeSiriLoggedItems() == nil)
    }

    @Test func takeSiriLoggedItemsReturnsNilWhenNothingIsWaiting() {
        #expect(store.takeSiriLoggedItems() == nil)
    }
}
```

**with:**

```swift
        #expect(store.takeSiriLoggedItems() == nil)
    }

    @Test func takeSiriLoggedItemsReturnsNilWhenNothingIsWaiting() {
        #expect(store.takeSiriLoggedItems() == nil)
    }

    @Test func foodsFromOneLookupAreLoggedOneMillisecondApart() throws {
        let total = store.addFoods(
            [LoggedFood(name: "Burger", carbs: 30), LoggedFood(name: "Fries", carbs: 48)],
            now: noon
        )

        #expect(total == 78)
        // Each gets its own Apple Health entry when the app imports them, and
        // the app deletes an entry by the millisecond it starts in.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let times = try store.siriLoggedItems().map { entry -> Date in
            let stamp = try #require(entry["loggedAt"] as? String)
            return try #require(formatter.date(from: stamp))
        }
        #expect(times.count == 2)
        #expect(abs(times[1].timeIntervalSince(times[0]) - 0.001) < 0.0001)
    }

    @Test func siriTimestampsKeepMilliseconds() throws {
        store.addFood(LoggedFood(name: "Toast", carbs: 15), now: noon.addingTimeInterval(0.25))

        let stamp = try #require(store.siriLoggedItems().first?["loggedAt"] as? String)
        #expect(stamp.contains(".250"))
    }
}
```


- [ ] **Step 2: Run them and watch them fail**

Run: `cd ios/CarbShared && swift test`
Expected: compile errors: no `unknownCarbs`, no `skipped:` argument, no `addFoods`.

- [ ] **Step 3: Parse unknown carbs and send the flag**

In `ios/CarbShared/Sources/CarbShared/PerplexityClient.swift`:

**Edit 1 of 3 — replace:**

```swift
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
```

**with:**

```swift
}

/// Every food the server found for one lookup ("burger and fries" → 2 items).
public struct LookupResult: Equatable, Sendable {
    public let items: [LookupItem]
    public let citations: [String]
    /// Foods the server found but had no reliable carb value for. Siri doesn't
    /// log them and says so; they never become a `LookupItem`, whose carbs are
    /// always a number.
    public let unknownCarbs: [String]

    public init(items: [LookupItem], citations: [String], unknownCarbs: [String] = []) {
        self.items = items
        self.citations = citations
        self.unknownCarbs = unknownCarbs
    }
}

extension LoggedFood {
    /// The buffered form of a looked-up item, keeping its macros.
    public init(item: LookupItem, citations: [String]) {
```

**Edit 2 of 3 — replace:**

```swift

        let body: [String: Any] = [
            "data": [
                "input": foodItem,
                // Lets the server count the free quota per local calendar day.
                "tzOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            ] as [String: Any]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
```

**with:**

```swift

        let body: [String: Any] = [
            "data": [
                "input": foodItem,
                // Lets the server count the free quota per local calendar day.
                "tzOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
                // This build handles a food with no carb value
                // (LookupResult.unknownCarbs). Without it the server drops such
                // foods, because older builds turned the missing value into 0.
                "acceptsUnknownCarbs": true,
            ] as [String: Any]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
```

**Edit 3 of 3 — replace:**

```swift
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

    /// A finite, non-negative number, or nil. Nutrition values can't be
    /// negative, and a NaN or infinity would make `JSONSerialization` in
    /// `CarbDataStore.addFood` raise an Objective-C exception Swift can't catch.
    private static func number(_ value: Any?) -> Double? {
```

**with:**

```swift
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let rawItems = result["items"] as? [[String: Any]] else {
            throw IntentError.message("Could not parse server response.")
        }

        var items: [LookupItem] = []
        var unknownCarbs: [String] = []
        for raw in rawItems {
            let name = raw["name"] as? String ?? "Unknown"
            // No carb value means the server couldn't find one. Never read as
            // 0: a confident 0 g is worse than no answer for someone dosing
            // insulin, so Siri skips the food and says so.
            guard let carbs = number(raw["carbs"]) else {
                unknownCarbs.append(name)
                continue
            }
            items.append(LookupItem(
                name: name,
                carbs: carbs,
                protein: number(raw["protein"]),
                fat: number(raw["fat"]),
                fiber: number(raw["fiber"]),
                calories: number(raw["calories"]),
                details: raw["details"] as? String
            ))
        }
        // Siri can't hand a food to Manual entry the way the app does, so
        // finding no carb values is the same as finding nothing.
        guard !items.isEmpty else {
            throw IntentError.message("I couldn't find nutrition info for that.")
        }
        return LookupResult(
            items: items,
            citations: result["citations"] as? [String] ?? [],
            unknownCarbs: unknownCarbs
        )
    }

    /// A finite, non-negative number, or nil. Nutrition values can't be
    /// negative, and a NaN or infinity would make `JSONSerialization` in
    /// `CarbDataStore.addFood` raise an Objective-C exception Swift can't catch.
    private static func number(_ value: Any?) -> Double? {
```


- [ ] **Step 4: Name skipped foods**

In `ios/CarbShared/Sources/CarbShared/LogFoodDialog.swift`:

**Edit 1 of 2 — replace:**

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
```

**with:**

```swift
import Foundation

/// What Siri says after logging food.
public enum LogFoodDialog {
    /// - Parameter skipped: foods the lookup had no carb value for. They weren't
    ///   logged, and Siri says so rather than leaving the user to wonder.
    public static func text(items: [LookupItem], totalToday: Double, skipped: [String] = []) -> String {
        let logged = loggedText(items: items, totalToday: totalToday)
        guard !skipped.isEmpty else { return logged }
        let them = skipped.count == 1 ? "it" : "them"
        return "\(logged) I couldn't find carbs for \(names(skipped)), so I didn't log \(them)."
    }

    private static func loggedText(items: [LookupItem], totalToday: Double) -> String {
        let total = "Your total today is \(grams(totalToday)) grams."
        let sum = items.reduce(0) { $0 + $1.carbs }
        switch items.count {
        case 1:
            return "\(items[0].name) has \(grams(items[0].carbs)) grams of carbs. \(total)"
        case 2:
```

**Edit 2 of 2 — replace:**

```swift
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
```

**with:**

```swift
            return "Logged \(part(items[0])), \(part(items[1])), and \(part(items[2])): \(grams(sum)) grams. \(total)"
        default:
            return "Logged \(items.count) items, \(grams(sum)) grams. \(total)"
        }
    }

    /// "fries", "fries and shake", "fries, shake, and cake" — the same serial
    /// comma the logged-items list uses when spoken.
    private static func names(_ names: [String]) -> String {
        switch names.count {
        case 0, 1: return names.joined()
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
    }

    private static func part(_ item: LookupItem) -> String {
        "\(item.name), \(grams(item.carbs)) grams"
    }

    private static func grams(_ value: Double) -> String {
        String(format: "%.1f", value)
```


- [ ] **Step 5: Keep milliseconds; add foods 1 ms apart**

In `ios/CarbShared/Sources/CarbShared/CarbDataStore.swift`:

**Edit 1 of 2 — replace:**

```swift
    ///
    /// Main-actor isolated: Siri runs in the app's process, and home_widget
    /// handles the app's App Group writes on the main thread, so each call's
    /// read-modify-write is serialized with them. That covers one call only:
    /// callers adding several items should add the batch and read the total in
    /// one main-actor hop, as `LogFoodIntent` does, so no app write lands between.
    @MainActor
    public func addFood(_ food: LoggedFood, now: Date = Date()) {
        let newTotal = snapshot(now: now).totalCarbs + food.carbs
        defaults?.set(newTotal, forKey: Keys.totalCarbs)
        defaults?.set(food.name, forKey: Keys.lastFoodName)
        defaults?.set(food.carbs, forKey: Keys.lastFoodCarbs)
```

**with:**

```swift
    ///
    /// Main-actor isolated: Siri runs in the app's process, and home_widget
    /// handles the app's App Group writes on the main thread, so each call's
    /// read-modify-write is serialized with them. That covers one call only:
    /// callers adding several items should add the batch and read the total in
    /// one main-actor hop, as `LogFoodIntent` does, so no app write lands between.
    /// Siri's timestamps keep milliseconds. Foods from one utterance are
    /// logged 1 ms apart (`addFoods`); whole seconds would collapse them back
    /// together, and deleting one from Apple Health would take the others.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Adds the foods from one lookup, each 1 ms after the one before, so each
    /// gets an Apple Health entry of its own when the app imports them — the
    /// app deletes a Health entry by the millisecond it starts in.
    ///
    /// One main-actor step, so no app write lands between the foods.
    ///
    /// - Returns: today's total afterwards.
    @MainActor
    @discardableResult
    public func addFoods(_ foods: [LoggedFood], now: Date = Date()) -> Double {
        for (index, food) in foods.enumerated() {
            addFood(food, now: now.addingTimeInterval(Double(index) / 1000))
        }
        return snapshot(now: now).totalCarbs
    }

    @MainActor
    public func addFood(_ food: LoggedFood, now: Date = Date()) {
        let newTotal = snapshot(now: now).totalCarbs + food.carbs
        defaults?.set(newTotal, forKey: Keys.totalCarbs)
        defaults?.set(food.name, forKey: Keys.lastFoodName)
        defaults?.set(food.carbs, forKey: Keys.lastFoodCarbs)
```

**Edit 2 of 2 — replace:**

```swift
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
```

**with:**

```swift
        defaults?.set(newTotal, forKey: Keys.flutterTotalCarbs)

        var buffer = siriLoggedItems()
        var entry: [String: Any] = [
            "name": food.name,
            "carbs": food.carbs,
            "loggedAt": Self.timestampFormatter.string(from: now),
        ]
        if let protein = food.protein { entry["protein"] = protein }
        if let fat = food.fat { entry["fat"] = fat }
        if let fiber = food.fiber { entry["fiber"] = fiber }
        if let calories = food.calories { entry["calories"] = calories }
        if let details = food.details { entry["details"] = details }
```


- [ ] **Step 6: Run the Swift tests**

Run: `cd ios/CarbShared && swift test`
Expected: `Test run with 48 tests in 6 suites passed`.

- [ ] **Step 7: Use it from the intent**

In `ios/Runner/CarbIntents.swift`:

**Edit 1 of 1 — replace:**

```swift
    var foodItem: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let idToken = try await SiriAuth.idToken()
        let result = try await PerplexityClient.lookupCarbs(for: foodItem, idToken: idToken)

        let now = Date()
        let totalToday = await MainActor.run { () -> Double in
            for item in result.items {
                CarbDataStore.shared.addFood(LoggedFood(item: item, citations: result.citations), now: now)
            }
            return CarbDataStore.shared.snapshot(now: now).totalCarbs
        }

        return .result(dialog: IntentDialog(stringLiteral: LogFoodDialog.text(items: result.items, totalToday: totalToday)))
    }
}

// MARK: - Check Carbs Intent

struct CheckCarbsIntent: AppIntent {
```

**with:**

```swift
    var foodItem: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let idToken = try await SiriAuth.idToken()
        let result = try await PerplexityClient.lookupCarbs(for: foodItem, idToken: idToken)

        let foods = result.items.map { LoggedFood(item: $0, citations: result.citations) }
        let totalToday = await MainActor.run {
            CarbDataStore.shared.addFoods(foods, now: Date())
        }

        return .result(dialog: IntentDialog(stringLiteral: LogFoodDialog.text(
            items: result.items, totalToday: totalToday, skipped: result.unknownCarbs)))
    }
}

// MARK: - Check Carbs Intent

struct CheckCarbsIntent: AppIntent {
```


- [ ] **Step 8: Build**

Run the iOS build from the Global Constraints.
Expected: `** BUILD SUCCEEDED **` with no new warnings.

- [ ] **Step 9: Commit**

```bash
git add ios/CarbShared/Sources/CarbShared/PerplexityClient.swift ios/CarbShared/Sources/CarbShared/LogFoodDialog.swift ios/CarbShared/Sources/CarbShared/CarbDataStore.swift ios/Runner/CarbIntents.swift ios/CarbShared/Tests/CarbSharedTests/PerplexityClientTests.swift ios/CarbShared/Tests/CarbSharedTests/LogFoodDialogTests.swift ios/CarbShared/Tests/CarbSharedTests/CarbDataStoreTests.swift
git commit -m "fix(siri): skip foods with unknown carbs and keep milliseconds"
```

---

### Task 6: Deploy and check by hand

Not code. Do this after the branch merges.

- [ ] **Step 1: Deploy the functions right away.** Old app builds are protected the moment the server knows the flag: they get the foods it found, or a named error, never a fabricated zero. So don't wait for the App Store release.

```bash
cd functions && npm test && firebase deploy --only functions
```

- [ ] **Step 2: Run the device checklist**
  - [ ] Look up "burger and fries", then delete fries. Only fries leaves Apple Health. Do the same through Siri.
  - [ ] Look up something with no reliable data (a made-up dish). The app says "Couldn't find carbs for … — enter it manually.", switches to Manual, and has the name filled in.
  - [ ] A lookup where one food is found and one isn't logs the found one and hands off the other.
  - [ ] Siri: "log burger and <made-up dish>" logs the burger and says it couldn't find carbs for the other.
  - [ ] Water logs as 0 g, not as unknown.
  - [ ] In Settings › Health, turn off read access for CarpeCarb and leave write on. Deleting a food still removes it from Health.
  - [ ] On a device still running the previous App Store build, a lookup for a made-up dish shows an error instead of 0 g.

---

## Notes for the reviewer

- The unknown-carbs contract has three layers (model prompt, server parse, client parse), and all three used to default to 0. A regression in any one of them brings back the confident 0 g.
- `acceptsUnknownCarbs` protects builds already on phones. The server filters on its absence, not its value, so leaving it out of a new client silently drops unknown foods rather than showing them.
- The 1 ms spacing only helps if every writer does it. Lookups space in `parseLookupResponse` and Siri in `CarbDataStore.addFoods`. Single adds are distinct already. A new path that writes several foods at once needs the same.
