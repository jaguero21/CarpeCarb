import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
import 'services/lookup_api.dart';
import 'services/perplexity_firebase_service.dart';
import 'services/health_kit_service.dart';
import 'services/premium_service.dart';
import 'services/cloud_sync_service.dart';
import 'services/siri_buffer_service.dart';
import 'services/siri_import.dart';
import 'services/sync_merge.dart';
import 'services/sync_payload.dart';
import 'services/sync_store.dart';
import 'models/food_item.dart';
import 'models/server_quota.dart';
import 'screens/settings_page.dart';
import 'config/app_colors.dart';
import 'config/app_theme.dart';
import 'config/storage_keys.dart';
import 'utils/a11y_labels.dart';
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
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final PerplexityFirebaseService _perplexityService =
      PerplexityFirebaseService();
  final HealthKitService _healthKitService = HealthKitService();
  final PremiumService _premiumService = PremiumService();
  final CloudSyncService _cloudSyncService = CloudSyncService();
  final SyncStore _syncStore = SyncStore();

  final SiriBufferService _siriBuffer = SiriBufferService();
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
    // Before the first merge: goals set on an older build have no timestamp,
    // which reads as "never set here" and loses to a device that has none.
    await _syncStore.stampExistingSettings();
    await _cloudSyncService.startListening(_onRemoteCloudChange);
    final pulled = await _cloudSyncService.pullFromCloud();
    // Merged unconditionally: merging is safe to repeat, and the timestamp
    // gate this replaced skipped remote changes whenever this device had
    // pushed more recently than the change it was ignoring.
    if (pulled != null && mounted) await _applyCloudData(pulled);
  }

  void _onRemoteCloudChange(Map<String, dynamic>? data) {
    if (data != null && mounted) _applyCloudData(data);
  }

  /// Pushes this device's state to iCloud: today's items and what was deleted
  /// today, the favourites and when each last changed, and the settings with
  /// the time they were last changed here. The other device needs all of it to
  /// merge instead of resurrecting what this one deleted.
  ///
  /// Call after the local change has been written to SharedPreferences —
  /// the payload is built from what is stored, not from in-memory state.
  Future<void> _pushLocalState() async {
    if (!_premiumService.isCloudSyncEnabled) return;
    final prefs = await SharedPreferences.getInstance();
    final state = await _syncStore.read(_todayString());
    final timestamp = DateTime.now();
    final pushed =
        await _pushToCloud(encodeSyncPayload(state, timestamp: timestamp));
    // Only advance the local timestamp when the push really landed, so a push
    // that failed (iCloud signed out) is retried on the next change.
    if (pushed) {
      await prefs.setString(
          StorageKeys.cloudLastModified, timestamp.toIso8601String());
    }
  }

  /// Merges a cloud payload into local data, then reloads the UI.
  ///
  /// The merge keeps both devices' items and favourites, honours deletes from
  /// either side, and takes the newer settings — see
  /// `lib/services/sync_merge.dart`. Launch, resume and a live remote change
  /// all come through here.
  Future<void> _applyCloudData(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final cloud = decodeSyncPayload(data);
    // Read, merge and write as one step, so a delete or favourite edit made
    // while this runs isn't dropped by the write that follows it.
    final merged = await _syncStore.mergeInto(
      _todayString(),
      (local) =>
          mergeSyncState(local: local, cloud: cloud, now: DateTime.now()),
    );

    // Kept as a record of what this device last saw, for support and for the
    // sync indicator; the decision to pull is the native side's, which holds
    // its own copy. Nothing in Dart reads this back.
    if (data[StorageKeys.cloudLastModified] is String) {
      await prefs.setString(StorageKeys.cloudLastModified,
          data[StorageKeys.cloudLastModified] as String);
    }

    // The Favourites screen keeps its own copy; without this it would write
    // its pre-merge list back over the merged one when the user edits there.
    if (mounted) setState(() => _favoritesVersion++);
    if (mounted) await _loadSavedData();

    // Push back only what the cloud is missing. When both sides already agree
    // the merge changes nothing, neither device pushes, and the pair settles
    // instead of answering each other's pushes forever.
    if (syncStateDiffers(merged, cloud)) await _pushLocalState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (!_premiumService.isCloudSyncEnabled) {
        _onResumed();
        _cloudSyncService.stopListening();
        return;
      }
      // Merge only once the resume has dealt with a new day. The other way
      // round, the merge's write can land before the new-day branch clears
      // yesterday, taking today's merged items with it — and the push-back
      // then sends an empty today to the other device.
      _onResumed().then((_) {
        if (!mounted) return;
        _cloudSyncService.pullFromCloud().then((pulled) {
          if (pulled != null && mounted) _applyCloudData(pulled);
        });
      });
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
      // New day — reset everything. The delete markers go with the items
      // they belong to; yesterday's cloud payload is ignored by the merge.
      await _syncStore.clearDay();
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
      // The list is replaced wholesale, so give the AnimatedList a new key:
      // its state still counts the items it had, and a merge that leaves
      // fewer would make it build rows that no longer exist (RangeError).
      _listKey = GlobalKey<AnimatedListState>();
    });

    // Pick up any food items logged via Siri while the app was closed
    await _importSiriLoggedItems();
  }

  Future<void> _importSiriLoggedItems() async {
    final token = ++_importSiriItemsToken;
    // Let a just-replaced list rebuild first (a new day, or a reload that
    // swapped in fewer items), so the inserts below don't hit the old
    // AnimatedList, which still counts the previous items.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || token != _importSiriItemsToken) return;
    // Taken and cleared in one native step: a Siri log that lands while this
    // runs is kept for the next import instead of being overwritten.
    final siriItemsJson = await _siriBuffer.takeLoggedItems();
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
    // Queued behind any merge in flight, so the two can't overwrite each
    // other's writes. The push happens afterwards, outside the queue, so a
    // slow channel call doesn't hold up the next save.
    await _syncStore.exclusively(() async {
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
    });

    await _pushLocalState();
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
      await _applyLookupResult(result);
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

  /// Logs the foods a lookup found and hands any it couldn't find a carb value
  /// for to Manual entry, so they're never logged as a guess.
  Future<void> _applyLookupResult(LookupResult result) async {
    final items = result.items;

    setState(() {
      isLoading = false;
      showingDailyTotal = false;
      _foodController.clear();
    });

    if (items.isNotEmpty) {
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
    }

    if (result.unknownCarbs.isNotEmpty && mounted) {
      _handOffUnknownCarbs(result.unknownCarbs);
    }
  }

  /// The lookup had no reliable carb value for [names]. Rather than log a
  /// number nobody could source, switch to Manual entry with the first one
  /// filled in so the user types it. Manual entry is open to every user
  /// (PremiumService.isManualEntryEnabled); if that ever changes, this needs
  /// another way out.
  void _handOffUnknownCarbs(List<String> names) {
    setState(() {
      _isManualEntryMode = true;
      _foodController.text = names.first;
      _carbController.clear();
    });
    _carbFocusNode.requestFocus();

    final them = names.length == 1 ? 'it' : 'them';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            "Couldn't find carbs for ${_listNames(names)} \u2014 enter $them manually."),
        backgroundColor: AppColors.honey.withValues(alpha: 0.9),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// "fries", "fries and shake", "fries, shake and cake".
  static String _listNames(List<String> names) => names.length <= 1
      ? names.join()
      : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

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
  void addSavedFoodForTest(FoodItem item) => _addSavedFood(item);
  Future<void> applyLookupResultForTest(LookupResult result) =>
      _applyLookupResult(result);
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
    _saveAfterDeleting(snapshot.map((item) => item.id).toList());
    _updateWidget();
  }

  /// Records [ids] as deleted today, then saves and pushes. The marker has to
  /// be written before the push so the payload carries it; without it the
  /// other device's copy of the item merges straight back in.
  Future<void> _saveAfterDeleting(List<String> ids) async {
    await _syncStore.recordItemsDeleted(ids);
    await _saveData();
  }

  /// Undo: the item is wanted again, so its delete marker goes.
  Future<void> _saveAfterRestoring(String id) async {
    await _syncStore.recordItemRestored(id);
    await _saveData();
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
    _saveAfterDeleting([removedItem.id]);
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
              _saveAfterRestoring(removedItem.id);
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
        // A pair of buttons, one of them selected — otherwise VoiceOver reads
        // two bare words and never says which mode is on. The visible Text is
        // the label, so the two can't drift apart.
        child: Semantics(
          button: true,
          selected: selected,
          inMutuallyExclusiveGroup: true,
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
          // The same two actions the row offers by swipe, for anyone who can't
          // swipe — with or without VoiceOver.
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _saveToSavedFoods(item);
            },
            child: const Text('Save to Food list'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final index = foodItems.indexWhere((f) => f.id == item.id);
              // Gone already if the list changed while the dialog was open.
              if (index != -1) removeItem(index);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.terracotta),
            child: const Text('Delete'),
          ),
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
    // Stamp the change so these settings win over an older device's.
    await _syncStore.markSettingsChanged();
    await _saveData();
    await _updateWidget();
  }

  /// Called by SettingsPage after it has written the favourites and recorded
  /// the change, so the new list reaches the other device.
  Future<void> _onFavoritesChanged() => _pushLocalState();

  /// [index] is the row's place in today's list, which the Delete action
  /// needs. It is null while a row animates out, where the actions would have
  /// nothing to act on.
  Widget _buildFoodTile(FoodItem item, {int? index}) {
    return Semantics(
      // One stop that reads like a sentence. Without this the name, the time
      // and the number are three separate stops, and the number has no unit.
      label: foodRowLabel(
        name: item.name,
        carbs: item.carbs,
        time: formatTime(item.loggedAt),
      ),
      hint: 'Double tap for details',
      onTap: () => _showFoodDetails(item),
      // Deleting and saving are swipes, which VoiceOver can't reach: its own
      // swipes move between elements. These put both in the Actions rotor.
      customSemanticsActions: {
        if (index != null)
          const CustomSemanticsAction(label: 'Delete'): () =>
              removeItem(index),
        const CustomSemanticsAction(label: 'Save to Food list'): () =>
            _saveToSavedFoods(item),
      },
      excludeSemantics: true,
      child: FoodItemCard(
        name: item.name,
        subtitle: formatTime(item.loggedAt),
        carbs: item.carbs,
        category: item.category,
        onLongPress: () => _showFoodDetails(item),
      ),
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

  void _addSavedFood(FoodItem saved) {
    // A new entry, logged now — not the stored favourite itself. Reusing it
    // would give two taps the same id and the same millisecond, and deleting
    // one would take the other out of Apple Health with it.
    final item = FoodItem(
      name: saved.name,
      carbs: saved.carbs,
      protein: saved.protein,
      fat: saved.fat,
      fiber: saved.fiber,
      calories: saved.calories,
      details: saved.details,
      citations: saved.citations,
      isManualEntry: saved.isManualEntry,
    );
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

      await _syncStore.recordFavoriteAdded(item.name);
      await _pushLocalState();

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
      // Icon-only status: without a label VoiceOver announces nothing, or
      // stops on an unnamed image.
      case _CloudSyncState.syncing:
        return Semantics(
          label: 'Syncing',
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppColors.sage,
            ),
          ),
        );
      case _CloudSyncState.synced:
        return Semantics(
          label: 'Synced',
          child: Icon(Icons.cloud_done, size: 16, color: AppColors.sage),
        );
      case _CloudSyncState.error:
        return Semantics(
          label: 'Sync failed',
          child: Tooltip(
            message: 'Cloud sync failed',
            child: Icon(Icons.cloud_off, size: 16, color: AppColors.terracotta),
          ),
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
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: tooltip,
        // 44x44 is the smallest hit area iOS asks for. At 40 these two were the
        // only controls in the app below that minimum. The circle itself stays
        // 40, but the wider box is a fixed-width child of a Row with a Spacer,
        // so it does move the header a little: the Home circle sits 6pt left of
        // where it used to, Settings 2pt left, and the taller row drops the
        // title and the content below it by a couple of points. Measured and
        // accepted — restoring the old pixels would mean three compensating
        // paddings that silently break the next time this row changes.
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
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
                    syncStore: _syncStore,
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
      // Tapping anywhere dismisses the keyboard. Without this, VoiceOver saw
      // an unlabelled button the size of the whole screen.
      excludeFromSemantics: true,
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
                    // One deliberate stop. Left alone these merge into
                    // "Apple 25.0g of 100g daily goal, 25" — the raw number,
                    // the goal line, and a bare percentage the progress bar
                    // contributes as its value.
                    child: Semantics(
                      label: showingDailyTotal || foodItems.isEmpty
                          ? "Today's total"
                          : foodItems.first.name,
                      // The card still draws the goal line and the progress
                      // bar in the single-food state, and `excludeSemantics`
                      // hides both — so the day has to be spoken here too or
                      // it is not spoken at all, which is the state the app
                      // is in after every add.
                      value: showingDailyTotal || foodItems.isEmpty
                          ? carbProgressValue(
                              total: totalCarbs, goal: dailyCarbGoal)
                          : '${spokenGrams(foodItems.first.carbs)}, '
                              '${carbProgressValue(total: totalCarbs, goal: dailyCarbGoal)} today',
                      // The card is a control, not a caption: tapping it
                      // toggles the two states above. The role and the hint
                      // are what make that — and the value above — reachable.
                      // Both are gated on the same condition as the
                      // GestureDetector's onTap, so an empty day doesn't
                      // announce a button with nothing to do.
                      button: foodItems.isNotEmpty,
                      hint: foodItems.isNotEmpty
                          ? "Double tap to switch between today's total and "
                              'the last food logged'
                          : null,
                      // The long press has no VoiceOver equivalent, so the
                      // page it opens is offered as a named action instead.
                      customSemanticsActions: {
                        const CustomSemanticsAction(label: 'Open settings'):
                            () {
                          HapticFeedback.mediumImpact();
                          _switchToPage(1);
                        },
                      },
                      excludeSemantics: true,
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
                                      : foodItems.first.carbs
                                          .toStringAsFixed(1),
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
                                value: (totalCarbs / dailyCarbGoal!)
                                    .clamp(0.0, 1.0),
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
                        // Announced as a button; the icon and the word
                        // "Reset" alone told VoiceOver nothing about what it
                        // was. It already asks for confirmation.
                        Semantics(
                          button: true,
                          child: GestureDetector(
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
                                child: _buildFoodTile(item, index: index),
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
