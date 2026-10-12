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
 * combining tilde becomes "ñ"), and tidies whitespace.
 */
function normalizeFoodInput(input) {
  return input
    .normalize("NFC")
    .replace(/[’‘ʼʹˈ`´ˊˋ＇՚׳′]/g, "'")
    // Double-quote lookalikes and the inch mark (double prime): 6” and 6″ mean 6".
    .replace(/[“”„″＂]/g, "\"")
    .replace(/[–—−]/g, "-")
    .replace(/\0/g, "")
    .replace(/\s+/g, " ")
    .trim();
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
