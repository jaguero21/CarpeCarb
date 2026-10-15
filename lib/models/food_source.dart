import 'food_item.dart';

/// Where a logged food's carb number came from, shown as a tag on its row so
/// someone deciding a dose can see how much to trust it.
enum FoodSource {
  usda,
  web,
  manual;

  String get label => switch (this) {
        FoodSource.usda => 'USDA',
        FoodSource.web => 'Web',
        FoodSource.manual => 'Manual',
      };

  /// As VoiceOver reads it in the row's label.
  String get spoken => switch (this) {
        FoodSource.usda => 'from USDA',
        FoodSource.web => 'from the web',
        FoodSource.manual => 'entered manually',
      };
}

/// The food's source, or null when it can't be told (foods looked up before
/// the USDA chain existed). Never guessed.
FoodSource? foodSourceOf(FoodItem item) {
  if (item.isManualEntry) return FoodSource.manual;
  switch (item.serving?.source) {
    case 'usda':
      return FoodSource.usda;
    case 'web':
      return FoodSource.web;
  }
  final details = item.details ?? '';
  // The prefixes the lookup server writes (functions/src/lookup.js).
  if (details.startsWith('USDA FoodData Central')) return FoodSource.usda;
  if (details.startsWith('Web source, not USDA.')) return FoodSource.web;
  return null;
}
