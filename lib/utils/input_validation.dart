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

  /// Converts lookalike characters to the ones the rules allow, and tidies
  /// whitespace. Applied before validation and before sending to the server.
  static String sanitizeForApi(String input) {
    return input
        // Apostrophe lookalikes, including the iPhone's curly apostrophe.
        .replaceAll(RegExp('[’‘ʼʹˈ`´ˊˋ＇՚׳′]'), "'")
        // Double-quote lookalikes and the inch mark (double prime): 6” and 6″ mean 6".
        .replaceAll(RegExp('[“”„″＂]'), '"')
        // Dash lookalikes.
        .replaceAll(RegExp('[–—−]'), '-')
        .replaceAll('\x00', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
