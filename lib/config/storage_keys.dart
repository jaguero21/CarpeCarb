/// Centralized storage keys shared between Dart and native iOS code.
/// If you change a key here, update the matching constant in
/// ios/CarbShared/Sources/CarbShared/CarbDataStore.swift
class StorageKeys {
  StorageKeys._();

  // App group identifier (must match Runner.entitlements)
  static const String appGroupId = 'group.com.carpecarb.shared';

  // SharedPreferences keys (local to Flutter)
  static const String totalCarbs = 'total_carbs';
  static const String foodItems = 'food_items';
  static const String lastSaveDate = 'last_save_date';
  static const String dailyCarbGoal = 'daily_carb_goal';
  static const String savedFoods = 'saved_foods';
  static const String dailyResetHour = 'daily_reset_hour';

  // HomeWidget / UserDefaults keys (shared with native iOS)
  static const String widgetTotalCarbs = 'totalCarbs';
  static const String widgetLastFoodName = 'lastFoodName';
  static const String widgetLastFoodCarbs = 'lastFoodCarbs';
  static const String widgetDailyCarbGoal = 'dailyCarbGoal';
  // Written by Siri (CarbDataStore.addFood) and taken by the app through
  // com.carpecarb/siribuffer, not read from here — see SiriBufferService.
  static const String widgetSiriLoggedItems = 'siriLoggedItems';
  static const String widgetFlutterTotalCarbs = 'flutter.total_carbs';
  // The day the widget totals belong to (lib/utils/day_key.dart) and the
  // user's reset hour, so Siri and the widget can tell a new day has started.
  static const String widgetDayKey = 'dayKey';
  static const String widgetResetHour = 'dailyResetHour';

  // iOS widget name
  static const String widgetName = 'CarbWiseWidget';

  // Subscription keys
  static const String isPremium = 'is_premium';
  static const String premiumPlan = 'premium_plan';

  // Macro goals
  static const String proteinGoal = 'protein_goal';
  static const String fatGoal = 'fat_goal';
  static const String fiberGoal = 'fiber_goal';
  static const String caloriesGoal = 'calories_goal';

  // Cloud sync
  static const String cloudLastModified = 'cloud_last_modified';
  // Ids deleted today, so a delete isn't undone by another device's copy.
  // Cleared with food_items on a new day.
  static const String foodItemsDeleted = 'food_items_deleted';
  // Favourite key (lower-cased name) -> {updatedAt, deleted}: the most recent
  // add or delete, so the newer one wins when devices merge.
  static const String savedFoodsChanges = 'saved_foods_changes';
  // When the user last changed goals or the reset hour on this device.
  static const String settingsUpdatedAt = 'settings_updated_at';

  // Disclaimer
  static const String disclaimerAccepted = 'disclaimer_accepted';

  // Daily AI lookup quota, cached from the server's `quota` response
  // (free users: 4/day, enforced by getMultipleCarbCounts)
  static const String dailyLookupCount = 'daily_lookup_count';
  static const String dailyLookupDate = 'daily_lookup_date';
  static const String dailyLookupLimit = 'daily_lookup_limit';
}
