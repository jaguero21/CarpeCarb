/// What VoiceOver reads for the parts of the app that are numbers, icons or
/// custom controls rather than plain text.
///
/// Pure functions, so the wording is tested in one place and can't drift from
/// screen to screen. They spell values out the way they should be spoken:
/// "25 grams", not the "25.0g" the card draws.
library;

/// A gram value as it should be spoken: "25 grams", "1 gram", "25.5 grams".
String spokenGrams(double value) => '${spokenNumber(value)} '
    '${spokenNumber(value) == '1' ? 'gram' : 'grams'}';

/// A number without a trailing ".0", which VoiceOver reads aloud as
/// "point zero".
String spokenNumber(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

/// One food in today's list, as a sentence rather than three separate stops:
/// "Apple, 25 grams of carbs, logged 8:30 AM".
String foodRowLabel({
  required String name,
  required double carbs,
  required String time,
}) =>
    '$name, ${spokenGrams(carbs)} of carbs, logged $time';

/// The day's progress bar, which otherwise announces nothing:
/// "45 of 100 grams", or "45 grams, no goal set" when no goal is set.
String carbProgressValue({required double total, double? goal}) =>
    goal == null || goal <= 0
        ? '${spokenGrams(total)}, no goal set'
        : '${spokenNumber(total)} of ${spokenGrams(goal)}';
