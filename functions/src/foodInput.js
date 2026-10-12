/**
 * Food input rules. The app enforces the same rules (lib/utils/input_validation.dart),
 * and both run test/fixtures/food-input-cases.json, so a lookup typed in the app and
 * one spoken to Siri (which reaches the server unchecked) are judged the same way.
 */

const { HttpsError } = require("firebase-functions/v2/https");

/** Letters and marks in any script, digits, space, and - , . ( ) & % ' / " + */
const ALLOWED = /^[\p{L}\p{M}\p{N} \-,.()&%'/"+]+$/u;
const HAS_LETTER = /\p{L}/u;
/** Whole words or phrases only, so "prompto pasta" or "ecosystem granola" pass. */
const BLOCKED = /\b(ignore|system|prompts?|instructions?|override|jailbreak|dan mode|pretend|act as|roleplay|forget)\b/i;

/**
 * Converts lookalike characters to the allowed ones, composes accents (so "n" plus a
 * combining tilde becomes "ñ"), trims the ends and collapses spaces.
 */
function normalizeFoodInput(input) {
  return input
    .normalize("NFC")
    // Apostrophe lookalikes. Not the backtick: it's a shell character, so it's rejected, never converted.
    .replace(/[\u2019\u2018\u02BC\u02B9\u02C8\u00B4\u02CA\u02CB\uFF07\u055A\u05F3\u2032]/g, "'")
    // Double-quote lookalikes and the inch mark (double prime): 6\u201D and 6\u2033 mean 6".
    .replace(/[\u201C\u201D\u201E\u2033\uFF02]/g, "\"")
    .replace(/[\u2013\u2014\u2212]/g, "-")
    // Only the ends are trimmed and runs of spaces collapsed. A null byte, tab or newline
    // inside the text stays, so the allow-list rejects it.
    .trim()
    .replace(/ +/g, " ");
}

/**
 * Null if the input is a usable food description, otherwise the message to show.
 * The messages match the app's word for word.
 *
 * @param {unknown} input
 * @returns {string|null}
 */
function validateFoodInput(input) {
  if (typeof input !== "string") return "Please enter a food item";
  const s = normalizeFoodInput(input);
  if (s.length === 0) return "Please enter a food item";
  if (s.length < 2) return "Food name must be at least 2 characters";
  if (s.length > 100) return "Food name is too long (max 100 characters)";
  if (!ALLOWED.test(s)) return "Please use only letters, numbers, and common punctuation";
  if (BLOCKED.test(s) || s.includes("&&") || s.includes("../") || !HAS_LETTER.test(s)) {
    return "Please enter a valid food name";
  }
  return null;
}

/**
 * Validates and normalizes the raw `input` from a lookup request.
 *
 * @param {unknown} input
 * @returns {string} the normalized input
 * @throws {HttpsError} invalid-argument, with the same message the app shows
 */
function sanitizeFoodInput(input) {
  const error = validateFoodInput(input);
  if (error) throw new HttpsError("invalid-argument", error);
  return normalizeFoodInput(input);
}

module.exports = { validateFoodInput, sanitizeFoodInput, normalizeFoodInput };
