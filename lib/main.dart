import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:keyboard_actions/keyboard_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:home_widget/home_widget.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'dart:convert';
import 'dart:io';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_import.dart';
import 'models/food_item.dart';
import 'models/server_quota.dart';
import 'screens/settings_page.dart';
import 'config/app_colors.dart';
import 'config/app_theme.dart';
import 'config/storage_keys.dart';
import 'utils/date_format.dart';
import 'utils/day_key.dart';
import 'utils/input_validation.dart';
import 'utils/user_facing_exception.dart';
import 'widgets/food_item_card.dart';

Future<void> main() async {
  // Ensure Flutter is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Sign in anonymously so Cloud Functions can verify the caller is our app.
  // This is non-blocking for existing signed-in users.
  if (FirebaseAuth.instance.currentUser == null) {
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (e) {
      // Auth failure is non-fatal — the app works without it, but Cloud
      // Functions will reject requests until this is resolved.
      if (kDebugMode) debugPrint('Anonymous sign-in failed: $e');
    }
  }

  // Initialize HomeWidget for iOS widget data sharing
  HomeWidget.setAppGroupId(StorageKeys.appGroupId);

  runApp(const CarbTrackerApp());
}

class CarbTrackerApp extends StatelessWidget {
  const CarbTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CarpeCarb',
      debugShowCheckedModeBanner: false,
      theme: lightTheme(),
      darkTheme: darkTheme(),
      themeMode: ThemeMode.system,
      home: const CarbTrackerHome(),
    );
  }
}

enum _CloudSyncState { idle, syncing, synced, error }

class CarbTrackerHome extends StatefulWidget {
  const CarbTrackerHome({super.key});

  @override
  State<CarbTrackerHome> createState() => CarbTrackerHomeState();
}

// Made public for testing
class CarbTrackerHomeState extends State<CarbTrackerHome>
    with WidgetsBindingObserver {
  final TextEditingController _foodController = TextEditingController();
  final TextEditingController _carbController = TextEditingController();
  final FocusNode _foodFocusNode = FocusNode();
  final FocusNode _carbFocusNode = FocusNode();
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final PerplexityFirebaseService _perplexityService =
      PerplexityFirebaseService();
  final HealthKitService _healthKitService = HealthKitService();
  final PremiumService _premiumService = PremiumService();
  final CloudSyncService _cloudSyncService = CloudSyncService();
  bool _isManualEntryMode = false;

  List<FoodItem> foodItems = [];
  double get totalCarbs => foodItems.fold(0.0, (sum, item) => sum + item.carbs);
  bool isLoading = false;
  bool showingDailyTotal = false;
  double? dailyCarbGoal;
  double? proteinGoal;
  double? fatGoal;
  double? fiberGoal;
  double? caloriesGoal;
  int resetHour = 0;
  int _currentPage = 0; // 0 = home, 1 = settings
  int _settingsInitialTab = 0;
  int _favoritesVersion = 0;
  int _loadSavedDataToken = 0;
  int _importSiriItemsToken = 0;
  bool _healthKitSyncError = false;
  _CloudSyncState _cloudSyncState = _CloudSyncState.idle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _premiumService.init().then((_) {
      if (mounted) setState(() {});
      if (Platform.isIOS) {
        _healthKitService.requestAuthorization();
      }
      _initCloudSync();
    });
    _loadSavedData();
    _checkWidgetLaunch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowDisclaimer();
    });
  }

  Future<void> _maybeShowDisclaimer() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(StorageKeys.disclaimerAccepted) == true) {
      if (mounted) _foodFocusNode.requestFocus();
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return AlertDialog(
          backgroundColor:
              colorScheme.surface.withValues(alpha: 0.97),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24)),
          title: Row(
            children: [
              Icon(Icons.info_outline,
                  color: AppColors.honey, size: 22),
              const SizedBox(width: 10),
              const Text('Health Disclaimer',
                  style: TextStyle(fontSize: 18)),
            ],
          ),
          content: Text(
            'CarpeCarb provides general nutrition information for '
            'reference purposes only.\n\n'
            'The carbohydrate and nutrition data shown in this app '
            'is not medical advice and should not be used to make '
            'medical or dietary decisions.\n\n'
            'Always consult a qualified healthcare professional '
            'before making changes to your diet, especially if you '
            'have diabetes, a metabolic condition, or any other '
            'health concern.',
            style: TextStyle(
              fontSize: 14,
              height: 1.55,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: Container(
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: TextButton(
                  onPressed: () async {
                    await prefs.setBool(
                        StorageKeys.disclaimerAccepted, true);
                    if (context.mounted) Navigator.pop(context);
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text(
                    'I Understand',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ),
          ],
          actionsPadding:
              const EdgeInsets.fromLTRB(20, 4, 20, 20),
        );
      },
    );
    if (mounted) _foodFocusNode.requestFocus();
  }

  Future<void> _initCloudSync() async {
    await _cloudSyncService.startListening(_onRemoteCloudChange);
    final pulled = await _cloudSyncService.pullFromCloud();
    if (pulled != null && mounted) {
      final prefs = await SharedPreferences.getInstance();
      final cloudTs = pulled[StorageKeys.cloudLastModified] as String? ?? '';
      final localTs = prefs.getString(StorageKeys.cloudLastModified) ?? '';
      final cloudDt = DateTime.tryParse(cloudTs);
      final localDt = DateTime.tryParse(localTs);
      if (cloudDt != null && (localDt == null || cloudDt.isAfter(localDt))) {
        await _applyCloudData(pulled);
      }
    }
  }

  void _onRemoteCloudChange(Map<String, dynamic>? data) {
    if (data != null && mounted) _applyCloudData(data);
  }

  /// Builds the payload of all syncable data for a cloud push.
  /// [timestamp] is written as [StorageKeys.cloudLastModified] so the caller
  /// can save it locally after a successful push.
  Map<String, dynamic> _buildSyncPayload(SharedPreferences prefs,
      {String? timestamp}) {
    return {
      StorageKeys.foodItems:
          jsonEncode(foodItems.map((f) => f.toJson()).toList()),
      StorageKeys.savedFoods: prefs.getString(StorageKeys.savedFoods) ?? '',
      StorageKeys.dailyCarbGoal: dailyCarbGoal ?? 0.0,
      StorageKeys.dailyResetHour: resetHour,
      StorageKeys.lastSaveDate: _todayString(),
      StorageKeys.proteinGoal: proteinGoal ?? 0.0,
      StorageKeys.fatGoal: fatGoal ?? 0.0,
      StorageKeys.fiberGoal: fiberGoal ?? 0.0,
      StorageKeys.caloriesGoal: caloriesGoal ?? 0.0,
      StorageKeys.cloudLastModified:
          timestamp ?? DateTime.now().toIso8601String(),
    };
  }

  /// Parses a JSON string into a list of FoodItems, returning [] on any error.
  List<FoodItem> _parseFoodItemJson(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final decoded = jsonDecode(json) as List<dynamic>;
      return decoded
          .map((e) => FoodItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Applies a cloud data payload to SharedPreferences then reloads state.
  /// Food items and favorites are merged with local data (not replaced) so that
  /// neither device loses its own data when syncing.
  Future<void> _applyCloudData(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();

    // ── Goals: await each write so _loadSavedData reads current values ──
    Future<void> applyGoal(String key, dynamic val) async {
      if (val is num && val.toDouble() > 0) {
        await prefs.setDouble(key, val.toDouble());
      } else if (val is num) {
        await prefs.remove(key);
      }
    }

    await Future.wait([
      applyGoal(StorageKeys.dailyCarbGoal, data[StorageKeys.dailyCarbGoal]),
      applyGoal(StorageKeys.proteinGoal, data[StorageKeys.proteinGoal]),
      applyGoal(StorageKeys.fatGoal, data[StorageKeys.fatGoal]),
      applyGoal(StorageKeys.fiberGoal, data[StorageKeys.fiberGoal]),
      applyGoal(StorageKeys.caloriesGoal, data[StorageKeys.caloriesGoal]),
    ]);

    final resetHourVal = data[StorageKeys.dailyResetHour];
    if (resetHourVal is num) {
      await prefs.setInt(StorageKeys.dailyResetHour, resetHourVal.toInt());
    }

    // ── Favorites: merge by name so neither device loses saved foods ──
    if (data[StorageKeys.savedFoods] is String) {
      final localFavs =
          _parseFoodItemJson(prefs.getString(StorageKeys.savedFoods));
      final cloudFavs =
          _parseFoodItemJson(data[StorageKeys.savedFoods] as String);
      final seen = <String>{};
      final mergedFavs = <FoodItem>[];
      for (final item in [...cloudFavs, ...localFavs]) {
        if (seen.add(item.name.toLowerCase())) mergedFavs.add(item);
      }
      await prefs.setString(StorageKeys.savedFoods,
          jsonEncode(mergedFavs.map((f) => f.toJson()).toList()));
    }

    // ── Food items: merge by loggedAt so both devices' logs are preserved ──
    bool pushedMergedList = false;
    final cloudSaveDate = data[StorageKeys.lastSaveDate] is String
        ? data[StorageKeys.lastSaveDate] as String
        : null;
    final today = _todayString();
    if (cloudSaveDate == today && data[StorageKeys.foodItems] is String) {
      final localItems =
          _parseFoodItemJson(prefs.getString(StorageKeys.foodItems));
      final cloudItems =
          _parseFoodItemJson(data[StorageKeys.foodItems] as String);

      // Combine, dedup by stable item ID, sort newest-first.
      // Cloud items take priority so the remote version wins on ID collision.
      final seen = <String>{};
      final merged = <FoodItem>[];
      for (final item in [...cloudItems, ...localItems]) {
        if (seen.add(item.id)) merged.add(item);
      }
      merged.sort((a, b) => b.loggedAt.compareTo(a.loggedAt));

      final mergedJson = jsonEncode(merged.map((f) => f.toJson()).toList());
      await prefs.setString(StorageKeys.foodItems, mergedJson);
      await prefs.setString(StorageKeys.lastSaveDate, today);

      // If we contributed local items the cloud didn't have, push the merged
      // list back so the other device also receives them.
      if (merged.length > cloudItems.length &&
          _premiumService.isCloudSyncEnabled) {
        final newTs = DateTime.now().toIso8601String();
        // Build push from current local state (not incoming data) so we don't
        // propagate stale goal/settings values that may have changed locally.
        final pushed = await _pushToCloud({
          ..._buildSyncPayload(prefs),
          StorageKeys.foodItems: mergedJson,
          StorageKeys.cloudLastModified: newTs,
        });
        // Only advance the local timestamp if the push succeeded. If it failed,
        // keep the old timestamp so we retry on next sync.
        if (pushed) {
          await prefs.setString(StorageKeys.cloudLastModified, newTs);
          pushedMergedList = true;
        }
      }
    }

    if (!pushedMergedList && data[StorageKeys.cloudLastModified] is String) {
      await prefs.setString(StorageKeys.cloudLastModified,
          data[StorageKeys.cloudLastModified] as String);
    }

    if (mounted) await _loadSavedData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _onResumed();
      if (_premiumService.isCloudSyncEnabled) {
        _cloudSyncService.pullFromCloud().then((pulled) {
          if (pulled != null && mounted) _applyCloudData(pulled);
        });
      } else {
        _cloudSyncService.stopListening();
      }
    }
  }

  /// On resume, start a new day if the app was suspended across the day
  /// boundary (its in-memory list is still yesterday's); otherwise just pick
  /// up Siri items. `_loadSavedData`'s new-day branch imports Siri items itself.
  Future<void> _onResumed() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lastSaveDate = prefs.getString(StorageKeys.lastSaveDate);
    if (lastSaveDate != null && lastSaveDate != _todayString()) {
      await _loadSavedData();
    } else {
      await _importSiriLoggedItems();
    }
  }

  Future<void> _checkWidgetLaunch() async {
    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    if (uri != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _foodFocusNode.requestFocus();
      });
    }
  }

  Future<void> _updateWidget() async {
    await HomeWidget.saveWidgetData<double>(
        StorageKeys.widgetTotalCarbs, totalCarbs);
    await HomeWidget.saveWidgetData<String>(
      StorageKeys.widgetLastFoodName,
      foodItems.isNotEmpty ? foodItems.first.name : '',
    );
    await HomeWidget.saveWidgetData<double>(
      StorageKeys.widgetLastFoodCarbs,
      foodItems.isNotEmpty ? foodItems.first.carbs : 0.0,
    );
    await HomeWidget.saveWidgetData<double>(
        StorageKeys.widgetDailyCarbGoal, dailyCarbGoal ?? 0.0);
    await _saveWidgetDay();
    await HomeWidget.updateWidget(iOSName: StorageKeys.widgetName);
  }

  /// Tells Siri and the widget which day the stored totals belong to.
  Future<void> _saveWidgetDay() async {
    await HomeWidget.saveWidgetData<String>(
        StorageKeys.widgetDayKey, _todayString());
    await HomeWidget.saveWidgetData<int>(StorageKeys.widgetResetHour, resetHour);
  }

  Future<void> _loadSavedData() async {
    final token = ++_loadSavedDataToken;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || token != _loadSavedDataToken) return;
    final savedGoal = prefs.getDouble(StorageKeys.dailyCarbGoal);
    final savedResetHour = prefs.getInt(StorageKeys.dailyResetHour) ?? 0;
    resetHour = savedResetHour;
    proteinGoal = prefs.getDouble(StorageKeys.proteinGoal);
    fatGoal = prefs.getDouble(StorageKeys.fatGoal);
    fiberGoal = prefs.getDouble(StorageKeys.fiberGoal);
    caloriesGoal = prefs.getDouble(StorageKeys.caloriesGoal);
    final lastSaveDate = prefs.getString(StorageKeys.lastSaveDate);
    final isNewDay = lastSaveDate != null && lastSaveDate != _todayString();

    if (isNewDay) {
      // New day — reset everything
      await prefs.remove(StorageKeys.foodItems);
      await prefs.remove(StorageKeys.lastSaveDate);
      await prefs.setDouble(StorageKeys.totalCarbs, 0.0);
      await HomeWidget.saveWidgetData<double>(
          StorageKeys.widgetTotalCarbs, 0.0);
      await HomeWidget.saveWidgetData<String>(
          StorageKeys.widgetLastFoodName, '');
      await HomeWidget.saveWidgetData<double>(
          StorageKeys.widgetLastFoodCarbs, 0.0);
      await _saveWidgetDay();
      await HomeWidget.updateWidget(iOSName: StorageKeys.widgetName);
      if (!mounted || token != _loadSavedDataToken) return;
      setState(() {
        foodItems = [];
        dailyCarbGoal = savedGoal;
      });
      // Let the emptied list rebuild first so the import doesn't insert into
      // the old AnimatedList, which still counts yesterday's items.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || token != _loadSavedDataToken) return;
      // Siri may have logged food this morning before the app was opened.
      await _importSiriLoggedItems();
      return;
    }

    // Same day — restore food list
    final itemsJson = prefs.getString(StorageKeys.foodItems);
    List<FoodItem> loadedItems = [];
    if (itemsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(itemsJson);
        loadedItems = decoded
            .map((item) => FoodItem.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (e) {
        if (kDebugMode) debugPrint('Failed to decode saved food_items: $e');
      }
    }

    if (!mounted || token != _loadSavedDataToken) return;
    setState(() {
      foodItems = loadedItems;
      dailyCarbGoal = savedGoal;
    });

    // Pick up any food items logged via Siri while the app was closed
    await _importSiriLoggedItems();
  }

  Future<void> _importSiriLoggedItems() async {
    final token = ++_importSiriItemsToken;
    final siriItemsJson = await HomeWidget.getWidgetData<String>(
        StorageKeys.widgetSiriLoggedItems);
    if (!mounted || token != _importSiriItemsToken) return;
    if (siriItemsJson == null) return;

    try {
      final siri =
          SiriImport.parse(siriItemsJson, DateTime.now(), resetHour);
      if (siri.today.isEmpty && siri.earlier.isEmpty) return;

      // Insert one at a time to keep AnimatedList's internal count in sync
      // with the data list.
      for (final foodItem in siri.today) {
        if (!mounted || token != _importSiriItemsToken) return;
        setState(() {
          foodItems.insert(0, foodItem);
        });
        _listKey.currentState
            ?.insertItem(0, duration: const Duration(milliseconds: 400));
      }

      // Clear the Siri buffer so we don't re-import on next launch
      await HomeWidget.saveWidgetData<String?>(
          StorageKeys.widgetSiriLoggedItems, null);
      await _saveData();
      await _updateWidget();

      // Items from an earlier day stay out of today's list but still go to
      // Apple Health at the time they were logged.
      if (_premiumService.isHealthSyncEnabled) {
        for (final foodItem in [...siri.today, ...siri.earlier]) {
          _writeToHealthKit(foodItem);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to import Siri logged items: $e');
    }
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(StorageKeys.totalCarbs, totalCarbs);
    if (dailyCarbGoal != null) {
      await prefs.setDouble(StorageKeys.dailyCarbGoal, dailyCarbGoal!);
    } else {
      await prefs.remove(StorageKeys.dailyCarbGoal);
    }
    final itemsJson = jsonEncode(foodItems.map((f) => f.toJson()).toList());
    await prefs.setString(StorageKeys.foodItems, itemsJson);
    await prefs.setString(StorageKeys.lastSaveDate, _todayString());

    // Push to iCloud if cloud sync is enabled
    if (_premiumService.isCloudSyncEnabled) {
      final ts = DateTime.now().toIso8601String();
      final pushed = await _pushToCloud(_buildSyncPayload(prefs, timestamp: ts));
      if (pushed) await prefs.setString(StorageKeys.cloudLastModified, ts);
    }
  }

  String _todayString() => dayKey(DateTime.now(), resetHour);

  String? _validateFoodInput(String input) {
    // Use hardened validation from InputValidation utility
    // Protects against: control chars, prompt injection, SQL syntax, etc.
    return InputValidation.validateFoodInput(input);
  }

  Future<void> _addFood() async {
    final foodText = _foodController.text.trim();

    // Validate input
    final validationError = _validateFoodInput(foodText);
    if (validationError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(validationError),
            backgroundColor: AppColors.honey.withValues(alpha: 0.9),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // Fast pre-check for free users; the server enforces the real limit.
    if (_premiumService.hasReachedDailyLimit) {
      if (mounted) _showLookupLimitDialog();
      return;
    }

    // Dismiss keyboard so the user can see results
    _dismissKeyboard();

    setState(() {
      isLoading = true;
    });

    try {
      final result = await _perplexityService.getMultipleCarbCounts(foodText);
      final quota = result.quota;
      if (quota != null) await _premiumService.applyServerQuota(quota);

      if (!mounted) return;

      final items = result.items;

      setState(() {
        isLoading = false;
        showingDailyTotal = false;
        _foodController.clear();
      });

      // Insert one at a time so AnimatedList and foodItems stay in sync
      // and every item gets its own entrance animation
      for (final item in items.reversed) {
        foodItems.insert(0, item);
        _listKey.currentState
            ?.insertItem(0, duration: const Duration(milliseconds: 400));
      }

      HapticFeedback.lightImpact();

      await _saveData();
      await _updateWidget();

      // Write each item to HealthKit
      for (final item in items) {
        _writeToHealthKit(item);
      }
    } on DailyLimitReachedException catch (e) {
      final limit = e.limit ?? _premiumService.dailyLookupLimit;
      await _premiumService.applyServerQuota(ServerQuota(
          premium: false, used: e.used ?? limit, limit: limit, dayKey: e.dayKey));
      if (!mounted) return;
      setState(() {
        isLoading = false;
      });
      _showLookupLimitDialog();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
      });

      if (mounted) {
        final errorMessage = e is UserFacingException
            ? e.message
            : 'Something went wrong. Please try again.';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: AppColors.terracotta.withValues(alpha: 0.9),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Dismiss',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ),
        );
      }
    }
  }

  void _addManualFood() {
    if (!_premiumService.isManualEntryEnabled) return;
    final name = _foodController.text.trim();
    final carbText = _carbController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please enter a food name'),
          backgroundColor: AppColors.honey.withValues(alpha: 0.9),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    final carbs = double.tryParse(carbText);
    if (carbs == null || carbs < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Carbs must be a number (e.g., 45 or 45.5)'),
          backgroundColor: AppColors.honey.withValues(alpha: 0.9),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    _dismissKeyboard();

    final item = FoodItem(name: name, carbs: carbs, isManualEntry: true);
    setState(() {
      foodItems.insert(0, item);
      showingDailyTotal = false;
      _foodController.clear();
      _carbController.clear();
    });
    _listKey.currentState
        ?.insertItem(0, duration: const Duration(milliseconds: 400));
    HapticFeedback.lightImpact();
    _saveData();
    _updateWidget();
    if (_premiumService.isHealthSyncEnabled) {
      _writeToHealthKit(item);
    }
  }

  void _showLookupLimitDialog() {
    final colorScheme = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.lock_clock_outlined, color: AppColors.terracotta, size: 22),
            const SizedBox(width: 10),
            const Expanded(child: Text('Daily Limit Reached')),
          ],
        ),
        content: Text(
          "You've used all ${_premiumService.dailyLookupLimit} free AI lookups for today.\n\n"
          "Subscribe to CarpeCarb for unlimited lookups every day. "
          "Manual entry is always available for free.",
          style: TextStyle(
            fontSize: 14,
            height: 1.55,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not Now'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _settingsInitialTab = 3);
              _switchToPage(1);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.sage),
            child: const Text('View Plans'),
          ),
        ],
      ),
    );
  }

  void _confirmReset() {
    if (foodItems.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset today\'s log?'),
        content: const Text('All food items will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _resetTotal();
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.terracotta),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  // Test hooks — allow tests to drive state without relying on off-screen UI.
  void resetTotalForTest() => _resetTotal();
  void switchToSettingsForTest() => _switchToPage(1);

  void _resetTotal() {
    // Capture items before clearing so animation builders have valid references.
    final snapshot = List<FoodItem>.from(foodItems);
    setState(() {
      foodItems.clear();
    });
    for (int i = snapshot.length - 1; i >= 0; i--) {
      final item = snapshot[i];
      _listKey.currentState?.removeItem(
        i,
        (context, animation) => _buildAnimatedItem(item, animation),
        duration: const Duration(milliseconds: 300),
      );
    }
    // Delete all reset items from HealthKit
    if (_premiumService.isHealthSyncEnabled) {
      for (final item in snapshot) {
        _deleteFromHealthKit(item);
      }
    }
    _saveData();
    _updateWidget();
  }

  void removeItem(int index) {
    final removedItem = foodItems[index];
    setState(() {
      foodItems.removeAt(index);
    });
    _listKey.currentState?.removeItem(
      index,
      (context, animation) => _buildAnimatedItem(removedItem, animation),
      duration: const Duration(milliseconds: 300),
    );
    _saveData();
    _updateWidget();
    if (_premiumService.isHealthSyncEnabled) {
      _deleteFromHealthKit(removedItem);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${removedItem.name} removed'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: 'Undo',
            textColor: Colors.white,
            onPressed: () {
              setState(() {
                foodItems.insert(index.clamp(0, foodItems.length), removedItem);
              });
              _listKey.currentState?.insertItem(
                index.clamp(0, foodItems.length - 1),
                duration: const Duration(milliseconds: 400),
              );
              _saveData();
              _updateWidget();
              if (_premiumService.isHealthSyncEnabled) {
                _writeToHealthKit(removedItem);
              }
            },
          ),
        ),
      );
    }
  }

  Widget _buildModeToggle() {
    Widget pill(
        {required String label,
        required bool selected,
        required VoidCallback onTap}) {
      return Expanded(
        child: GestureDetector(
          onTap: () {
            _dismissKeyboard();
            onTap();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.sage
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? AppColors.sage
                    : Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.2),
              ),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          pill(
            label: 'Auto',
            selected: !_isManualEntryMode,
            onTap: () => setState(() => _isManualEntryMode = false),
          ),
          const SizedBox(width: 8),
          pill(
            label: 'Manual',
            selected: _isManualEntryMode,
            onTap: () => setState(() => _isManualEntryMode = true),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedItem(FoodItem item, Animation<double> animation) {
    return SizeTransition(
      sizeFactor: animation,
      child: FadeTransition(
        opacity: animation,
        child: _buildFoodTile(item),
      ),
    );
  }

  Future<void> _showFoodDetails(FoodItem item) async {
    final showMacros = _premiumService.isMacrosEnabled && item.hasMacros;
    final recognizers = <TapGestureRecognizer>[];
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => AlertDialog(
        backgroundColor:
            Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
        title: Text(item.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showMacros) ...[
                _buildMacroGrid(item, context),
                const SizedBox(height: 16),
              ],
              RichText(
                text: _buildDetailsTextSpan(
                  item.details ?? 'No details available for this item.',
                  item.citations,
                  baseColor: Theme.of(context).colorScheme.onSurface,
                  recognizers: recognizers,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    for (final r in recognizers) {
      r.dispose();
    }
  }

  Widget _buildMacroGrid(FoodItem item, BuildContext context) {
    final tiles = <_MacroTile>[
      _MacroTile('Carbs', item.carbs, 'g'),
      if (item.protein != null) _MacroTile('Protein', item.protein!, 'g'),
      if (item.fat != null) _MacroTile('Fat', item.fat!, 'g'),
      if (item.fiber != null) _MacroTile('Fiber', item.fiber!, 'g'),
      if (item.calories != null) _MacroTile('Calories', item.calories!, 'kcal'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: tiles.map((t) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.sage.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Text(
                '${t.value.toStringAsFixed(t.unit == 'kcal' ? 0 : 1)}${t.unit}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              Text(
                t.label,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  /// Writes a food item to HealthKit and tracks sync status.
  /// Only notifies the user the first time a failure occurs (when transitioning
  /// from OK → failed) so batch writes don't stack up multiple snackbars.
  void _writeToHealthKit(FoodItem item) {
    _healthKitService.writeFoodItem(item).then((success) {
      if (!mounted) return;
      if (!success) {
        final wasOk = !_healthKitSyncError;
        setState(() => _healthKitSyncError = true);
        if (wasOk) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                  'Health sync failed — check permissions in Settings'),
              backgroundColor: AppColors.terracotta.withValues(alpha: 0.9),
              duration: const Duration(seconds: 4),
              action: SnackBarAction(
                label: 'Settings',
                textColor: Colors.white,
                onPressed: () => setState(() => _currentPage = 1),
              ),
            ),
          );
        }
      } else if (_healthKitSyncError) {
        setState(() => _healthKitSyncError = false);
      }
    });
  }

  /// Deletes a food item from HealthKit and tracks sync status.
  void _deleteFromHealthKit(FoodItem item) {
    _healthKitService.deleteFoodItem(item).then((success) {
      if (!mounted) return;
      if (!success) {
        final wasOk = !_healthKitSyncError;
        setState(() => _healthKitSyncError = true);
        if (wasOk) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                  'Health sync failed — check permissions in Settings'),
              backgroundColor: AppColors.terracotta.withValues(alpha: 0.9),
              duration: const Duration(seconds: 4),
              action: SnackBarAction(
                label: 'Settings',
                textColor: Colors.white,
                onPressed: () => setState(() => _currentPage = 1),
              ),
            ),
          );
        }
      } else if (_healthKitSyncError) {
        setState(() => _healthKitSyncError = false);
      }
    });
  }

  /// Pushes [payload] to iCloud and tracks sync state for the UI indicator.
  /// Returns true if the push succeeded (mirrors [CloudSyncService.pushToCloud]).
  Future<bool> _pushToCloud(Map<String, dynamic> payload) async {
    if (!mounted) return false;
    setState(() => _cloudSyncState = _CloudSyncState.syncing);
    final pushed = await _cloudSyncService.pushToCloud(payload);
    if (!mounted) return pushed;
    if (pushed) {
      setState(() => _cloudSyncState = _CloudSyncState.synced);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _cloudSyncState == _CloudSyncState.synced) {
          setState(() => _cloudSyncState = _CloudSyncState.idle);
        }
      });
    } else {
      setState(() => _cloudSyncState = _CloudSyncState.error);
    }
    return pushed;
  }

  /// Validates and opens a citation URL.
  /// Only http/https URLs are permitted; anything else (or a parse failure)
  /// shows a brief error message instead of crashing or opening an unsafe URI.
  Future<void> _launchCitationUrl(String raw) async {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open citation link.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open citation link.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Builds a TextSpan that renders [N] citation references as tappable links.
  /// Pass a [recognizers] list to collect created recognizers for later disposal.
  TextSpan _buildDetailsTextSpan(String text, List<String> citations,
      {required Color baseColor, List<TapGestureRecognizer>? recognizers}) {
    final spans = <InlineSpan>[];
    final citationPattern = RegExp(r'\[(\d+)\]');
    var lastEnd = 0;

    for (final match in citationPattern.allMatches(text)) {
      // Add plain text before this citation
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
        ));
      }

      final refNumber = int.tryParse(match.group(1)!) ?? 0;
      final citationIndex = refNumber - 1;
      final hasUrl = citationIndex >= 0 && citationIndex < citations.length;

      GestureRecognizer? recognizer;
      if (hasUrl) {
        final r = TapGestureRecognizer()
          ..onTap = () => _launchCitationUrl(citations[citationIndex]);
        recognizers?.add(r);
        recognizer = r;
      }

      spans.add(TextSpan(
        text: '[${match.group(1)}]',
        style: TextStyle(
          color: hasUrl ? AppColors.sage : AppColors.muted,
          fontWeight: hasUrl ? FontWeight.w600 : FontWeight.normal,
          decoration: hasUrl ? TextDecoration.underline : TextDecoration.none,
        ),
        recognizer: recognizer,
      ));

      lastEnd = match.end;
    }

    // Add remaining text after last citation
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return TextSpan(
      style: TextStyle(
        fontSize: 15,
        color: baseColor,
        height: 1.5,
      ),
      children: spans,
    );
  }

  void _switchToPage(int page) {
    _dismissKeyboard();
    setState(() => _currentPage = page);
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _focusNextHomeInput() {
    if (_isManualEntryMode && _premiumService.isManualEntryEnabled) {
      _carbFocusNode.requestFocus();
      return;
    }
    _dismissKeyboard();
    _addFood();
  }

  Widget _homeKeyboardToolbarButton({
    required String label,
    required VoidCallback onPressed,
    bool isPrimary = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: () {
        HapticFeedback.lightImpact();
        onPressed();
      },
      style: TextButton.styleFrom(
        foregroundColor: isPrimary ? AppColors.sage : colorScheme.onSurface,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: isPrimary ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }

  KeyboardActionsConfig _buildHomeKeyboardActionsConfig() {
    return KeyboardActionsConfig(
      keyboardActionsPlatform: KeyboardActionsPlatform.IOS,
      keyboardBarColor: Theme.of(context).colorScheme.surface,
      actions: [
        KeyboardActionsItem(
          focusNode: _foodFocusNode,
          toolbarButtons: [
            if (_isManualEntryMode && _premiumService.isManualEntryEnabled)
              (_) => _homeKeyboardToolbarButton(
                    label: 'Next',
                    onPressed: _focusNextHomeInput,
                  ),
            (_) => _homeKeyboardToolbarButton(
                  label: (_isManualEntryMode &&
                          _premiumService.isManualEntryEnabled)
                      ? 'Done'
                      : 'Add',
                  isPrimary: true,
                  onPressed: () {
                    _dismissKeyboard();
                    if (!_isManualEntryMode ||
                        !_premiumService.isManualEntryEnabled) {
                      _addFood();
                    }
                  },
                ),
          ],
        ),
        KeyboardActionsItem(
          focusNode: _carbFocusNode,
          toolbarButtons: [
            (_) => _homeKeyboardToolbarButton(
                  label: 'Previous',
                  onPressed: () => _foodFocusNode.requestFocus(),
                ),
            (_) => _homeKeyboardToolbarButton(
                  label: 'Add',
                  isPrimary: true,
                  onPressed: () {
                    _dismissKeyboard();
                    _addManualFood();
                  },
                ),
          ],
        ),
      ],
    );
  }

  Future<void> _applySettingsResult(SettingsResult result) async {
    setState(() {
      dailyCarbGoal = result.dailyCarbGoal;
      resetHour = result.resetHour;
      proteinGoal = result.proteinGoal;
      fatGoal = result.fatGoal;
      fiberGoal = result.fiberGoal;
      caloriesGoal = result.caloriesGoal;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.dailyResetHour, resetHour);
    await _saveData();
    await _updateWidget();
  }

  /// Called by SettingsPage when favorites are added/removed, so we can push
  /// the full sync payload (which includes saved_foods) to iCloud.
  Future<void> _onFavoritesChanged() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = DateTime.now().toIso8601String();
    final pushed = await _pushToCloud(_buildSyncPayload(prefs, timestamp: ts));
    if (pushed) await prefs.setString(StorageKeys.cloudLastModified, ts);
  }

  Widget _buildFoodTile(FoodItem item) {
    return FoodItemCard(
      name: item.name,
      subtitle: formatTime(item.loggedAt),
      carbs: item.carbs,
      category: item.category,
      onLongPress: () => _showFoodDetails(item),
    );
  }

  Widget _buildMacroStrip(bool isDark) {
    var protein = 0.0, fat = 0.0, fiber = 0.0, calories = 0.0;
    for (final i in foodItems) {
      protein += i.protein ?? 0;
      fat += i.fat ?? 0;
      fiber += i.fiber ?? 0;
      calories += i.calories ?? 0;
    }

    Widget col(String label, double value, double? goal,
        {bool isCalories = false}) {
      final unit = isCalories ? '' : 'g';
      final valueStr = value.toStringAsFixed(0);
      final goalStr = goal != null
          ? (isCalories
              ? ' / ${goal.toStringAsFixed(0)}'
              : ' / ${goal.toStringAsFixed(0)}g')
          : null;

      return Expanded(
        child: Column(
          children: [
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: '$valueStr$unit',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  if (goalStr != null)
                    TextSpan(
                      text: goalStr,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    Widget divider() => Container(
          width: 1,
          height: 32,
          color: Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.15),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 6,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          col('Protein', protein, proteinGoal),
          divider(),
          col('Fat', fat, fatGoal),
          divider(),
          col('Fiber', fiber, fiberGoal),
          divider(),
          col('Calories', calories, caloriesGoal, isCalories: true),
        ],
      ),
    );
  }

  void _addSavedFood(FoodItem item) {
    setState(() {
      foodItems.insert(0, item);
      showingDailyTotal = false;
    });
    _listKey.currentState
        ?.insertItem(0, duration: const Duration(milliseconds: 400));
    _saveData();
    _updateWidget();
    if (_premiumService.isHealthSyncEnabled) {
      _writeToHealthKit(item);
    }
  }

  Future<void> _saveToSavedFoods(FoodItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final savedJson = prefs.getString(StorageKeys.savedFoods);

    List<FoodItem> savedFoods = [];
    if (savedJson != null) {
      final List<dynamic> decoded = jsonDecode(savedJson);
      savedFoods = decoded.map((item) => FoodItem.fromJson(item)).toList();
    }

    // Check if item already exists
    final exists = savedFoods
        .any((food) => food.name.toLowerCase() == item.name.toLowerCase());

    if (!exists) {
      savedFoods.add(item);
      final encoded = jsonEncode(savedFoods.map((f) => f.toJson()).toList());
      await prefs.setString(StorageKeys.savedFoods, encoded);
      setState(() => _favoritesVersion++);

      if (_premiumService.isCloudSyncEnabled) {
        final ts = DateTime.now().toIso8601String();
        final pushed = await _pushToCloud(_buildSyncPayload(prefs, timestamp: ts));
        if (pushed) await prefs.setString(StorageKeys.cloudLastModified, ts);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${item.name} saved to Food list'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${item.name} is already saved'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Widget _buildCloudSyncIndicator() {
    switch (_cloudSyncState) {
      case _CloudSyncState.syncing:
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: AppColors.sage,
          ),
        );
      case _CloudSyncState.synced:
        return Icon(Icons.cloud_done, size: 16, color: AppColors.sage);
      case _CloudSyncState.error:
        return Tooltip(
          message: 'Cloud sync failed',
          child: Icon(Icons.cloud_off, size: 16, color: AppColors.terracotta),
        );
      case _CloudSyncState.idle:
        return const SizedBox.shrink();
    }
  }

  Widget _buildNavIcon({
    required int page,
    required Widget icon,
    required String tooltip,
  }) {
    final isActive = _currentPage == page;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => _switchToPage(page),
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive
                ? (isDark ? AppColors.lightInk : AppColors.charcoal)
                : Colors.transparent,
          ),
          child: Center(child: icon),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Column(
          children: [
            // Shared AppBar
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 16, 0),
              child: Row(
                children: [
                  Text(
                    'CarpeCarb',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  if (Platform.isIOS && _premiumService.isCloudSyncEnabled)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _buildCloudSyncIndicator(),
                    ),
                  if (Platform.isIOS &&
                      _premiumService.isHealthSyncEnabled &&
                      _healthKitSyncError)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Tooltip(
                        message: 'Health sync failed — check permissions',
                        child: GestureDetector(
                          onTap: () => setState(() => _currentPage = 1),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Icon(Icons.favorite,
                                  size: 18, color: AppColors.terracotta),
                              Positioned(
                                right: -2,
                                top: -2,
                                child: Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: AppColors.terracotta,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surface,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  _buildNavIcon(
                    page: 0,
                    icon: Icon(
                      Icons.restaurant,
                      size: 20,
                      color: _currentPage == 0
                          ? (isDark ? AppColors.darkBackground : Colors.white)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    tooltip: 'Home',
                  ),
                  const SizedBox(width: 8),
                  _buildNavIcon(
                    page: 1,
                    icon: Icon(
                      Icons.settings,
                      size: 20,
                      color: _currentPage == 1
                          ? (isDark ? AppColors.darkBackground : Colors.white)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    tooltip: 'Settings',
                  ),
                ],
              ),
            ),

            // Page content
            Expanded(
              child: IndexedStack(
                index: _currentPage,
                children: [
                  _buildHomePage(isDark),
                  SettingsPage(
                    key: ValueKey(_settingsInitialTab),
                    favoritesVersion: _favoritesVersion,
                    dailyCarbGoal: dailyCarbGoal,
                    resetHour: resetHour,
                    onAddFood: _addSavedFood,
                    healthKitService: _healthKitService,
                    onSettingsChanged: _applySettingsResult,
                    onFavoritesChanged: _onFavoritesChanged,
                    premiumService: _premiumService,
                    cloudSyncService: _cloudSyncService,
                    onCloudSyncEnabled: () async {
                      await _initCloudSync();
                      await _saveData();
                    },
                    initialTab: _settingsInitialTab,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomePage(bool isDark) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissKeyboard,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          left: 24.0,
          right: 24.0,
          top: 16.0,
          bottom: 24.0 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: KeyboardActions(
          config: _buildHomeKeyboardActionsConfig(),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Total Carbs Card
                GestureDetector(
                  onTap: foodItems.isNotEmpty
                      ? () {
                          setState(() {
                            showingDailyTotal = !showingDailyTotal;
                          });
                          HapticFeedback.lightImpact();
                        }
                      : null,
                  onLongPress: () {
                    HapticFeedback.mediumImpact();
                    _switchToPage(1);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkSurface : Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black
                              .withValues(alpha: isDark ? 0.3 : 0.08),
                          blurRadius: 6,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        // "Today's Total" badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.sage.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            showingDailyTotal || foodItems.isEmpty
                                ? "Today's Total"
                                : foodItems.first.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AppColors.sage,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Large carb number
                        RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: showingDailyTotal || foodItems.isEmpty
                                    ? totalCarbs.toStringAsFixed(1)
                                    : foodItems.first.carbs.toStringAsFixed(1),
                                style: TextStyle(
                                  fontSize: 64,
                                  fontWeight: FontWeight.w300,
                                  color:
                                      Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              TextSpan(
                                text: 'g',
                                style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w300,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (dailyCarbGoal != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            totalCarbs > dailyCarbGoal!
                                ? '${(totalCarbs - dailyCarbGoal!).toStringAsFixed(0)}g over goal'
                                : 'of ${dailyCarbGoal!.toStringAsFixed(0)}g daily goal',
                            style: TextStyle(
                              fontSize: 14,
                              color: totalCarbs > dailyCarbGoal!
                                  ? AppColors.terracotta
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Linear progress bar
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value:
                                  (totalCarbs / dailyCarbGoal!).clamp(0.0, 1.0),
                              minHeight: 8,
                              backgroundColor: isDark
                                  ? AppColors.darkBorderMedium
                                  : const Color(0xFFE5E7EB),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                totalCarbs > dailyCarbGoal!
                                    ? AppColors.terracotta
                                    : AppColors.sage,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Macro totals strip (premium, only when data exists)
                if (_premiumService.isMacrosEnabled &&
                    foodItems.any((i) => i.hasMacros)) ...[
                  _buildMacroStrip(isDark),
                  const SizedBox(height: 16),
                ],

                // Input Card
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkSurface : Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                        blurRadius: 6,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // Mode toggle (Auto / Manual)
                      if (_premiumService.isManualEntryEnabled)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _buildModeToggle(),
                          ),
                        ),
                      TextField(
                        controller: _foodController,
                        focusNode: _foodFocusNode,
                        textInputAction: (_isManualEntryMode &&
                                _premiumService.isManualEntryEnabled)
                            ? TextInputAction.next
                            : TextInputAction.done,
                        decoration: InputDecoration(
                          hintText: _isManualEntryMode
                              ? 'Food name...'
                              : 'Enter food item...',
                          hintStyle: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.5),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                        onSubmitted: (_) => _focusNextHomeInput(),
                        onTapOutside: (_) => _dismissKeyboard(),
                      ),
                      if (_isManualEntryMode &&
                          _premiumService.isManualEntryEnabled) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _carbController,
                          focusNode: _carbFocusNode,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          textInputAction: TextInputAction.done,
                          decoration: InputDecoration(
                            hintText: 'Carbs (g)',
                            suffixText: 'g',
                            hintStyle: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withValues(alpha: 0.5),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 14,
                            ),
                          ),
                          onSubmitted: (_) {
                            _dismissKeyboard();
                            _addManualFood();
                          },
                          onTapOutside: (_) => _dismissKeyboard(),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: AppColors.primaryGradient,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.sage.withValues(alpha: 0.2),
                                blurRadius: 15,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: ElevatedButton(
                            onPressed: isLoading
                                ? null
                                : ((_isManualEntryMode &&
                                        _premiumService.isManualEntryEnabled)
                                    ? _addManualFood
                                    : _addFood),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: isLoading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(Icons.add,
                                          size: 20, color: Colors.white),
                                      const SizedBox(width: 8),
                                      Text(
                                        _isManualEntryMode ? 'Add' : 'Add Food',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // Food List Header
                if (foodItems.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        // Green vertical bar
                        Container(
                          width: 4,
                          height: 20,
                          decoration: BoxDecoration(
                            color: AppColors.sage,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'TODAY',
                          style: TextStyle(
                            fontSize: 14,
                            letterSpacing: 1.5,
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: _confirmReset,
                          child: Row(
                            children: [
                              Icon(
                                Icons.refresh,
                                size: 16,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Reset',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                // Food List
                foodItems.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32.0),
                          child: Text(
                            'Type a food name above to look up its carbs.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      )
                    : AnimatedList(
                        key: _listKey,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        initialItemCount: foodItems.length,
                        itemBuilder: (context, index, animation) {
                          final item = foodItems[index];
                          return SizeTransition(
                            sizeFactor: animation,
                            child: FadeTransition(
                              opacity: animation,
                              child: Dismissible(
                                key: Key(item.id),
                                direction: DismissDirection.horizontal,
                                confirmDismiss: (direction) async {
                                  if (direction ==
                                      DismissDirection.startToEnd) {
                                    HapticFeedback.lightImpact();
                                    await _saveToSavedFoods(item);
                                    return false;
                                  } else {
                                    HapticFeedback.mediumImpact();
                                    return true;
                                  }
                                },
                                onDismissed: (_) => removeItem(index),
                                background: Container(
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(left: 16),
                                  decoration: BoxDecoration(
                                    color: AppColors.sage,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(
                                    Icons.bookmark,
                                    size: 28,
                                    color: Colors.white,
                                  ),
                                ),
                                secondaryBackground: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 16),
                                  decoration: BoxDecoration(
                                    color: AppColors.terracotta,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(
                                    Icons.delete,
                                    size: 28,
                                    color: Colors.white,
                                  ),
                                ),
                                child: _buildFoodTile(item),
                              ),
                            ),
                          );
                        },
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _loadSavedDataToken++;
    _importSiriItemsToken++;
    WidgetsBinding.instance.removeObserver(this);
    _cloudSyncService.stopListening();
    _foodController.dispose();
    _carbController.dispose();
    _foodFocusNode.dispose();
    _carbFocusNode.dispose();
    super.dispose();
  }
}

class _MacroTile {
  final String label;
  final double value;
  final String unit;
  const _MacroTile(this.label, this.value, this.unit);
}
