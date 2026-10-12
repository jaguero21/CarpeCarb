/// Food input rules for CarpeCarb.
///
/// The server enforces the same rules (functions/src/foodInput.js), and both
/// run the shared cases in functions/test/fixtures/food-input-cases.json, so
/// a lookup typed in the app and one spoken to Siri are judged the same way.
library;

class InputValidation {
  /// Letters and marks in any script, digits, space, and the punctuation food
  /// names use: - , . ( ) & % ' / " +
  static final RegExp _allowed =
      RegExp(r"""^[\p{L}\p{M}\p{N} \-,.()&%'/"+]+$""", unicode: true);

  static final RegExp _hasLetter = RegExp(r'\p{L}', unicode: true);

  /// Whole words or phrases only, so "prompto pasta" or "ecosystem granola"
  /// aren't caught by a word they merely contain.
  static final RegExp _blocked = RegExp(
    r"\b(ignore|system|prompts?|instructions?|override|jailbreak|dan mode|"
    r"pretend|act as|roleplay|forget)\b",
    caseSensitive: false,
  );

  /// Returns null if [input] is a usable food description, or the message to
  /// show if it isn't.
  static String? validateFoodInput(String input) {
    final normalized = sanitizeForApi(input);

    if (normalized.isEmpty) return 'Please enter a food item';
    if (normalized.length < 2) {
      return 'Food name must be at least 2 characters';
    }
    if (normalized.length > 100) {
      return 'Food name is too long (max 100 characters)';
    }
    if (!_allowed.hasMatch(normalized)) {
      return 'Please use only letters, numbers, and common punctuation';
    }
    if (_blocked.hasMatch(normalized) ||
        normalized.contains('&&') ||
        normalized.contains('../') ||
        !_hasLetter.hasMatch(normalized)) {
      return 'Please enter a valid food name';
    }
    return null;
  }

  /// Converts lookalike characters to the ones the rules allow, trims the
  /// ends and collapses spaces. Applied before validation and before sending
  /// to the server.
  static String sanitizeForApi(String input) {
    return input
        // Apostrophe lookalikes, including the iPhone's curly apostrophe. Not the
        // backtick: it's a shell character, so it's rejected, never converted.
        .replaceAll(RegExp('[\u2019\u2018\u02BC\u02B9\u02C8\u00B4\u02CA\u02CB\uFF07\u055A\u05F3\u2032]'), "'")
        // Double-quote lookalikes and the inch mark (double prime): 6\u201D and 6\u2033 mean 6".
        .replaceAll(RegExp('[\u201C\u201D\u201E\u2033\uFF02]'), '"')
        // Dash lookalikes.
        .replaceAll(RegExp('[\u2013\u2014\u2212]'), '-')
        // Only the ends are trimmed and runs of spaces collapsed. A null byte,
        // tab or newline inside the text stays, so the allow-list rejects it.
        .trim()
        .replaceAll(RegExp(' +'), ' ');
  }
}
