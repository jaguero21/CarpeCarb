import 'package:carb_tracker/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which moment the day-boundary timer is armed for.
///
/// The timer used to be armed in initState, synchronously, while
/// `_loadSavedData` was still awaiting SharedPreferences — so it always used
/// the default reset hour of 0 and armed for midnight. With a 4am reset, an app
/// opened late at night and left open missed the real rollover: food logged
/// after 4am landed on yesterday's list, the save stamped today's day key, and
/// when the midnight timer finally fired it saw "same day" and counted
/// yesterday's carbs in today's total for good.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in const [
      'home_widget',
      'com.carpecarb/cloudsync',
      'com.carpecarb/siribuffer',
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (call) async => null);
    }
  });

  testWidgets('the timer is armed for the saved reset hour, not midnight',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'disclaimer_accepted': true,
      'daily_reset_hour': 4,
    });

    await tester.pumpWidget(const CarbTrackerApp());
    await tester.pumpAndSettle();

    final state =
        tester.state<CarbTrackerHomeState>(find.byType(CarbTrackerHome));
    final armed = state.scheduledDayBoundary;

    expect(armed, isNotNull);
    expect(armed!.hour, 4, reason: 'armed for ${armed.toIso8601String()}');
    expect(armed.minute, 0);
  });
}
