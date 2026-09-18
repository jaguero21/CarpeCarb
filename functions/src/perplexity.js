const { HttpsError } = require("firebase-functions/v2/https");

/**
 * Validates and sanitizes the raw `input` from a lookup request.
 * Mirrors InputValidation.sanitizeForApi + _normalizeUnicode in the Flutter app.
 *
 * @param {unknown} input
 * @returns {string} sanitized input
 */
function sanitizeFoodInput(input) {
  if (!input || typeof input !== "string") {
    throw new HttpsError("invalid-argument", "input is required");
  }
  const trimmed = input.trim();
  if (trimmed.length < 2 || trimmed.length > 100) {
    throw new HttpsError(
      "invalid-argument",
      "input must be 2-100 characters"
    );
  }

  return trimmed
    // Normalize Unicode confusables before allow-list enforcement
    .replace(/[\u2019\u2018\u02BC\u0060\u00B4]/g, "'") // apostrophe lookalikes
    .replace(/[\u2013\u2014\u2212]/g, "-")              // dash lookalikes
    .replace(/[\n\r\t]/g, " ")
    .replace(/\0/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

/** Marks an error as one where Perplexity did not bill us, so the caller may refund the lookup. */
function notBilled(err) {
  err.notBilled = true;
  return err;
}

/** True when a lookupFoods error means no billable completion was produced. */
function isNotBilled(err) {
  return Boolean(err && err.notBilled === true);
}

/**
 * Looks up carb counts for a sanitized food description via Perplexity.
 *
 * Errors thrown before a completion was produced (auth, rate limit, server
 * or network failure) are marked with notBilled; errors after a billed
 * completion (truncated or unparseable output) are not.
 *
 * @param {string} sanitized - output of sanitizeFoodInput
 * @param {string} apiKey - Perplexity API key
 * @param {{fetchImpl?: typeof fetch, sleep?: (ms: number) => Promise<void>}} [options] - injectable for tests
 * @returns {Promise<{items: object[], citations: string[]}>}
 */
async function lookupFoods(sanitized, apiKey, { fetchImpl = fetch, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  console.log(`Looking up: "${sanitized}"`);

  const maxAttempts = 3;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const response = await fetchImpl(
        "https://api.perplexity.ai/chat/completions",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            model: "sonar-pro",
            messages: [
              {
                role: "system",
                content:
                  "You are a precise nutrition assistant. The user will describe one or more food items. " +
                  "Interpret the input carefully: words may refer to a brand/store name, a style/variety, or the actual food product. " +
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
            ],
            max_tokens: 1024,
            temperature: 0.1,
          }),
        }
      );

      if (response.status === 401) {
        console.error("Perplexity API auth failed (401)");
        throw notBilled(new HttpsError("internal", "API authentication failed"));
      }
      if (response.status === 429) {
        console.error("Perplexity API rate limited (429)");
        throw notBilled(new HttpsError(
          "resource-exhausted",
          "Rate limit exceeded. Try again later."
        ));
      }
      if (response.status >= 500) {
        console.error(`Perplexity API server error (${response.status}), attempt ${attempt}/${maxAttempts}`);
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw notBilled(new HttpsError("internal", "Server error. Try again later."));
      }
      if (!response.ok) {
        const errorBody = await response.text();
        console.error(`Perplexity API error (${response.status}): ${errorBody}`);
        throw notBilled(new HttpsError(
          "internal",
          `API request failed (${response.status})`
        ));
      }

      const result = await response.json();

      if (!result.choices || !result.choices[0]) {
        console.error("Invalid API response structure:", JSON.stringify(result).substring(0, 500));
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Invalid API response");
      }

      if (result.choices[0].finish_reason === "length") {
        console.error(`Response truncated at max_tokens for input of ${sanitized.length} chars`);
        throw new HttpsError(
          "invalid-argument",
          "Too many foods in one lookup. Try fewer items."
        );
      }

      let content = result.choices[0].message.content.trim();
      const citations = result.citations || [];

      console.log("Raw API response content:", content);

      // Strip markdown code fences if present
      content = content.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();

      // Parse JSON array from response
      const arrayMatch = content.match(/\[[\s\S]*\]/);
      if (!arrayMatch) {
        console.error(`Could not find JSON array (attempt ${attempt}/${maxAttempts}):`, content);
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
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "Could not parse food items");
      }

      if (!Array.isArray(items) || items.length === 0) {
        console.error(`Empty result array (attempt ${attempt}/${maxAttempts}):`, JSON.stringify(items));
        if (attempt < maxAttempts) {
          await sleep(attempt * 1000);
          continue;
        }
        throw new HttpsError("internal", "No food items found in response");
      }

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
      if (error instanceof HttpsError) throw error;

      console.error(`Attempt ${attempt}/${maxAttempts} failed:`, error.message);

      // Retry on transient errors
      if (attempt < maxAttempts) {
        await sleep(attempt * 1000);
        continue;
      }

      throw notBilled(new HttpsError("internal", error.message));
    }
  }
}

module.exports = { sanitizeFoodInput, lookupFoods, notBilled, isNotBilled };
