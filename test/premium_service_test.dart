import 'package:carb_tracker/models/server_quota.dart';
import 'package:carb_tracker/services/premium_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DateTime now;
  PremiumService makeService() => PremiumService(clock: () => now);

  setUp(() {
    now = DateTime(2026, 9, 18, 21, 0);
    SharedPreferences.setMockInitialValues({});
  });

  test('applyServerQuota caches used and limit for today', () async {
    final svc = makeService();
    await svc.init();

    await svc.applyServerQuota(const ServerQuota(premium: false, used: 3, limit: 4));

    expect(svc.dailyLookupCount, 3);
    expect(svc.dailyLookupLimit, 4);
    expect(svc.hasReachedDailyLimit, isFalse);

    await svc.applyServerQuota(const ServerQuota(premium: false, used: 4, limit: 4));
    expect(svc.hasReachedDailyLimit, isTrue);
  });

  test('cached count stops blocking once the day rolls over, without a restart', () async {
    final svc = makeService();
    await svc.init();
    await svc.applyServerQuota(const ServerQuota(premium: false, used: 4, limit: 4));
    expect(svc.hasReachedDailyLimit, isTrue);

    now = DateTime(2026, 9, 19, 0, 5); // app stayed alive past midnight

    expect(svc.dailyLookupCount, 0);
    expect(svc.hasReachedDailyLimit, isFalse);
  });

  test('server premium=false turns off a local premium flag', () async {
    SharedPreferences.setMockInitialValues({'is_premium': true, 'premium_plan': 'monthly'});
    final svc = makeService();
    await svc.init();

    await svc.applyServerQuota(const ServerQuota(premium: false, used: 1, limit: 4));

    expect(svc.isPremium, isFalse);
    expect(svc.premiumPlan, isNull);
  });

  test('server premium=true turns premium on and keeps the stored plan', () async {
    SharedPreferences.setMockInitialValues({'premium_plan': 'yearly'});
    final svc = makeService();
    await svc.init();

    await svc.applyServerQuota(const ServerQuota(premium: true));

    expect(svc.isPremium, isTrue);
    expect(svc.premiumPlan, 'yearly');
    expect(svc.hasReachedDailyLimit, isFalse);
  });

  test('limit falls back to 4 before the server has reported one', () async {
    final svc = makeService();
    await svc.init();
    expect(svc.dailyLookupLimit, PremiumService.freeDailyLookupLimit);
    expect(PremiumService.freeDailyLookupLimit, 4);
  });
}
