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

/// The exact opening of a USDA result's details: `usdaItem` in
/// functions/src/lookup.js writes `USDA FoodData Central (<dataType>): `, with
/// dataType from DATA_TYPES in functions/src/usda.js. Anything looser would
/// tag a number that didn't come from the USDA calculation, because an AI
/// answer or an older saved food can also begin "USDA FoodData Central".
final _usdaDetails = RegExp(
    r'^USDA FoodData Central \((?:Survey \(FNDDS\)|SR Legacy|Foundation|Branded)\): ');

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
  if (_usdaDetails.hasMatch(details)) return FoodSource.usda;
  // A fixed label the server adds (functions/src/lookup.js), never model text.
  if (details.startsWith('Web source, not USDA.')) return FoodSource.web;
  return null;
}
