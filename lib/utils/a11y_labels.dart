/// What VoiceOver reads for the parts of the app that are numbers, icons or
/// custom controls rather than plain text.
///
/// Pure functions, so the wording is tested in one place and can't drift from
/// screen to screen. They spell values out the way they should be spoken:
/// "25 grams", not the "25.0g" the card draws.
library;

import '../models/serving_info.dart';

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
  String? serving,
}) =>
    serving == null
        ? '$name, ${spokenGrams(carbs)} of carbs, logged $time'
        : '$name, ${spokenGrams(carbs)} of carbs, $serving, logged $time';

/// The servings stepper's value: "1 serving", "2.5 servings".
String servingsValue(double count) =>
    count == 1 ? '1 serving' : '${formatCount(count)} servings';

/// A logged food's serving as it should be spoken, where the row's subtitle
/// ([ServingInfo.rowLabel]) draws "×" and "g": "2 servings of 1 cup, 480 grams".
/// Null when there is nothing to add, like the subtitle.
String? spokenServing(ServingInfo s) {
  if (!s.isUsda) return s.count == 1 ? null : servingsValue(s.count);
  final p = s.portion!;
  final grams = spokenGrams((p.grams * s.count).roundToDouble());
  return s.count == 1
      ? '${p.label}, $grams'
      : '${servingsValue(s.count)} of ${p.label}, $grams';
}

/// One option in the portion menu, with its weight: "1 cup · 120 g".
String portionOptionLabel(String label, double grams) => '$label · ${grams.round()} g';

/// The day's progress bar, which otherwise announces nothing:
/// "45 of 100 grams", or "45 grams, no goal set" when no goal is set. Over the
/// goal it adds "120 of 100 grams, 20 grams over goal", matching the
/// "20g over goal" line the card draws in terracotta.
///
/// Its Swift twin, `CarbAccessibility.carbsValue`, deliberately stops at the
/// two numbers: the widget already speaks "+20g over" as its own element, so
/// saying it there too would say it twice.
String carbProgressValue({required double total, double? goal}) {
  if (goal == null || goal <= 0) return '${spokenGrams(total)}, no goal set';
  final base = '${spokenNumber(total)} of ${spokenGrams(goal)}';
  return total > goal ? '$base, ${spokenGrams(total - goal)} over goal' : base;
}
