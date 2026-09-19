import 'package:shared_preferences/shared_preferences.dart';
import '../config/storage_keys.dart';
import '../models/server_quota.dart';

class PremiumService {
  PremiumService({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const String monthlyPlan = 'monthly';
  static const String yearlyPlan = 'yearly';

  /// Fallback for display before the server has reported a limit. The
  /// server's FREE_DAILY_LOOKUP_LIMIT (functions/src/quota.js) is the authority.
  static const int freeDailyLookupLimit = 4;

  final DateTime Function() _clock;
  SharedPreferences? _prefs;

  bool get _isReady => _prefs != null;

  bool get isPremium =>
      (_isReady ? _prefs!.getBool(StorageKeys.isPremium) : null) ?? false;
  String? get premiumPlan =>
      _isReady ? _prefs!.getString(StorageKeys.premiumPlan) : null;

  // All features are available to everyone — subscription unlocks unlimited AI lookups.
  bool get isManualEntryEnabled => true;
  bool get isHealthSyncEnabled => true;
  bool get isCloudSyncEnabled => true;
  bool get isMacrosEnabled => true;

  /// Local calendar day, matching the server's dayKey for this device.
  String _todayKey() => _clock().toIso8601String().substring(0, 10);

  /// Lookups used today, as last reported by the server. 0 once the cached
  /// day is no longer today, so a long-running app doesn't stay locked out.
  int get dailyLookupCount {
    if (!_isReady) return 0;
    if (_prefs!.getString(StorageKeys.dailyLookupDate) != _todayKey()) return 0;
    return _prefs!.getInt(StorageKeys.dailyLookupCount) ?? 0;
  }

  int get dailyLookupLimit =>
      (_isReady ? _prefs!.getInt(StorageKeys.dailyLookupLimit) : null) ??
      freeDailyLookupLimit;

  /// Fast pre-check that skips a request the server would refuse. The server
  /// still decides; this only reflects its last answer.
  bool get hasReachedDailyLimit =>
      !isPremium && dailyLookupCount >= dailyLookupLimit;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await resetLookupCountIfNewDay();
  }

  /// Resets the daily lookup count if the stored date is not today.
  Future<void> resetLookupCountIfNewDay() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    final today = _todayKey();
    final storedDate = prefs.getString(StorageKeys.dailyLookupDate);
    if (storedDate != today) {
      await prefs.setInt(StorageKeys.dailyLookupCount, 0);
      await prefs.setString(StorageKeys.dailyLookupDate, today);
    }
  }

  /// Caches the server's view of this user's quota and premium status.
  /// Premium follows the server, so a lapsed or refunded subscription
  /// reverts to free on the next lookup.
  Future<void> applyServerQuota(ServerQuota quota) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    if (quota.premium != isPremium) {
      await setPremiumEnabled(quota.premium);
    }
    final used = quota.used;
    final limit = quota.limit;
    if (!quota.premium && used != null && limit != null) {
      await prefs.setInt(StorageKeys.dailyLookupCount, used);
      await prefs.setInt(StorageKeys.dailyLookupLimit, limit);
      // The server's day, not ours: a lookup that finishes just after local
      // midnight was counted against yesterday and must not block today.
      await prefs.setString(StorageKeys.dailyLookupDate, quota.dayKey ?? _todayKey());
    }
  }

  Future<void> setPremiumPlan(String? plan) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    if (plan == null || plan.isEmpty) {
      await prefs.remove(StorageKeys.premiumPlan);
      return;
    }
    await prefs.setString(StorageKeys.premiumPlan, plan);
  }

  Future<void> setPremiumEnabled(bool value, {String? plan}) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setBool(StorageKeys.isPremium, value);
    if (value && plan != null && plan.isNotEmpty) {
      await prefs.setString(StorageKeys.premiumPlan, plan);
    }
    if (!value) {
      await prefs.remove(StorageKeys.premiumPlan);
    }
  }
}
