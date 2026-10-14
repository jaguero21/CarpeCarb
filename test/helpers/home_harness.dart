import 'dart:convert';

import 'package:carb_tracker/utils/day_key.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Today's day key at the default reset hour, as the app stores it.
String todayKey() => dayKey(DateTime.now(), 0);

/// SharedPreferences values for a day that already has [foods] logged, with
/// the disclaimer accepted.
Map<String, Object> todayPrefs(List<Map<String, Object?>> foods,
        {Map<String, Object> extra = const {}}) =>
    {
      'food_items': jsonEncode(foods),
      'last_save_date': todayKey(),
      'disclaimer_accepted': true,
      ...extra,
    };

/// Stubs the channels the home screen calls, so saves and pushes complete.
/// [siriItems] is handed over once by the Siri buffer, as Siri would.
void stubHomeChannels({String? siriItems}) {
  final appGroup = <String, Object?>{};
  _messenger.setMockMethodCallHandler(const MethodChannel('home_widget'),
      (call) async {
    final args = (call.arguments as Map?) ?? const {};
    if (call.method == 'saveWidgetData') {
      appGroup[args['id'] as String] = args['data'];
      return true;
    }
    if (call.method == 'getWidgetData') return appGroup[args['id'] as String];
    return null;
  });
  _messenger.setMockMethodCallHandler(
      const MethodChannel('com.carpecarb/cloudsync'), (call) async => false);
  var pending = siriItems;
  _messenger.setMockMethodCallHandler(
      const MethodChannel('com.carpecarb/siribuffer'), (call) async {
    final items = pending;
    pending = null;
    return items;
  });
  addTearDown(() {
    for (final name in const [
      'home_widget',
      'com.carpecarb/cloudsync',
      'com.carpecarb/siribuffer',
    ]) {
      _messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
}
