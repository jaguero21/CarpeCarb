import 'package:carb_tracker/widgets/quick_log_chips.dart';
import 'package:flutter_test/flutter_test.dart';

/// A chip's name, scoped to the quick-add row. The name and the carbs are
/// separate texts, so the name can be cut off without losing the carbs.
Finder chipName(String name) =>
    find.descendant(of: find.byType(QuickLogChips), matching: find.text(name));

/// A chip's carbs, e.g. `chipCarbs(27)` finds ' · 27.0 g'.
Finder chipCarbs(num carbs) => find.descendant(
    of: find.byType(QuickLogChips),
    matching: find.text(' · ${carbs.toStringAsFixed(1)} g'));
