/// The serving a looked-up food was logged at, and everything needed to
/// change it on the device: USDA foods carry their portions and per-100 g
/// values; web foods carry the values they were looked up with.
library;

/// Rounds to 1 decimal the way the server does (`Math.round(v * 10) / 10`).
double round1(double v) => (v * 10).round() / 10;

/// A count as people read it: "3", "2.5", "0.75".
String formatCount(double count) {
  final rounded = (count * 100).round() / 100;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toString();
}

double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

class Nutrients {
  const Nutrients({required this.carbs, this.protein, this.fat, this.fiber, this.calories});

  final double carbs;
  final double? protein;
  final double? fat;
  final double? fiber;
  final double? calories;

  Nutrients scaled(double factor) {
    double? s(double? v) => v == null ? null : round1(v * factor);
    return Nutrients(
      carbs: s(carbs)!,
      protein: s(protein),
      fat: s(fat),
      fiber: s(fiber),
      calories: s(calories),
    );
  }

  Map<String, dynamic> toJson() => {
        'carbs': carbs,
        if (protein != null) 'protein': protein,
        if (fat != null) 'fat': fat,
        if (fiber != null) 'fiber': fiber,
        if (calories != null) 'calories': calories,
      };

  static Nutrients? fromJson(Object? json) {
    if (json is! Map) return null;
    final carbs = _num(json['carbs']);
    if (carbs == null || carbs < 0) return null;
    return Nutrients(
      carbs: carbs,
      protein: _num(json['protein']),
      fat: _num(json['fat']),
      fiber: _num(json['fiber']),
      calories: _num(json['calories']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Nutrients &&
      other.carbs == carbs &&
      other.protein == protein &&
      other.fat == fat &&
      other.fiber == fiber &&
      other.calories == calories;

  @override
  int get hashCode => Object.hash(carbs, protein, fat, fiber, calories);

  @override
  String toString() =>
      'Nutrients(carbs: $carbs, protein: $protein, fat: $fat, fiber: $fiber, calories: $calories)';
}

class ServingPortion {
  const ServingPortion({required this.id, required this.label, required this.grams});

  final String id;
  final String label;
  final double grams;

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'grams': grams};

  static ServingPortion? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final label = json['label'];
    final grams = _num(json['grams']);
    if (id is! String || label is! String || grams == null || grams <= 0) return null;
    return ServingPortion(id: id, label: label, grams: grams);
  }

  @override
  bool operator ==(Object other) =>
      other is ServingPortion && other.id == id && other.label == label && other.grams == grams;

  @override
  int get hashCode => Object.hash(id, label, grams);
}

class ServingInfo {
  static const double step = 0.5;
  static const double minCount = 0.5;
  static const double maxCount = 20;
  // The server accepts 0.25–20, so a stored count may start below the stepper's minimum.
  static const double _minStored = 0.25;

  const ServingInfo._({
    required this.source,
    required this.count,
    this.fdcId,
    this.portions = const [],
    this.per100g,
    this.base,
    this.portionId,
  });

  factory ServingInfo.usda({
    required int fdcId,
    required List<ServingPortion> portions,
    required Nutrients per100g,
    required String portionId,
    required double count,
  }) =>
      ServingInfo._(
          source: 'usda',
          fdcId: fdcId,
          portions: List.unmodifiable(portions),
          per100g: per100g,
          portionId: portionId,
          count: count);

  factory ServingInfo.web({required Nutrients base, double count = 1}) =>
      ServingInfo._(source: 'web', base: base, count: count);

  final String source;
  final int? fdcId;
  final List<ServingPortion> portions;
  final Nutrients? per100g;
  final Nutrients? base;
  final String? portionId;
  final double count;

  bool get isUsda => source == 'usda';

  ServingPortion? get portion {
    for (final p in portions) {
      if (p.id == portionId) return p;
    }
    return null;
  }

  bool get canDecrease => count - step >= minCount - 1e-9;
  bool get canIncrease => count + step <= maxCount + 1e-9;

  /// The food's nutrients at this serving, rounded like the server.
  Nutrients nutrients() {
    if (isUsda) {
      final grams = portion!.grams * count;
      final p = per100g!;
      double? s(double? v) => v == null ? null : round1(v * grams / 100);
      return Nutrients(
        carbs: s(p.carbs)!,
        protein: s(p.protein),
        fat: s(p.fat),
        fiber: s(p.fiber),
        calories: s(p.calories),
      );
    }
    return base!.scaled(count);
  }

  ServingInfo copyWith({String? portionId, double? count}) => ServingInfo._(
        source: source,
        fdcId: fdcId,
        portions: portions,
        per100g: per100g,
        base: base,
        portionId: portionId ?? this.portionId,
        count: count ?? this.count,
      );

  ServingInfo decreased() => canDecrease ? copyWith(count: count - step) : this;
  ServingInfo increased() => canIncrease ? copyWith(count: count + step) : this;

  /// What the food row shows next to the time, or null for nothing extra.
  String? rowLabel() {
    if (isUsda) {
      final p = portion!;
      if (count == 1) return '${p.label} (${p.grams.round()} g)';
      return '${formatCount(count)} × ${p.label} (${(p.grams * count).round()} g)';
    }
    return count == 1 ? null : '×${formatCount(count)}';
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'count': count,
        if (fdcId != null) 'fdcId': fdcId,
        if (portions.isNotEmpty) 'portions': portions.map((p) => p.toJson()).toList(),
        if (per100g != null) 'per100g': per100g!.toJson(),
        if (base != null) 'base': base!.toJson(),
        if (portionId != null) 'portionId': portionId,
      };

  static bool _countOk(double? c) => c != null && c >= _minStored && c <= maxCount;

  static List<ServingPortion>? _portions(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final out = <ServingPortion>[];
    for (final r in raw) {
      final p = ServingPortion.fromJson(r);
      if (p == null) return null;
      out.add(p);
    }
    return out;
  }

  static int? _int(Object? v) =>
      v is int ? v : (v is num && v == v.roundToDouble() ? v.toInt() : null);

  static ServingInfo? _usda(Object? fdcIdRaw, Object? portionsRaw, Object? per100gRaw,
      Object? portionId, double? count) {
    final fdcId = _int(fdcIdRaw);
    final portions = _portions(portionsRaw);
    final per100g = Nutrients.fromJson(per100gRaw);
    if (fdcId == null || portions == null || per100g == null) return null;
    if (portionId is! String || !portions.any((p) => p.id == portionId)) return null;
    if (!_countOk(count)) return null;
    return ServingInfo.usda(
        fdcId: fdcId, portions: portions, per100g: per100g, portionId: portionId, count: count!);
  }

  /// The stored form, as written by [toJson]. Anything malformed gives null:
  /// the food then simply has no picker.
  static ServingInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final count = _num(json['count']);
    switch (json['source']) {
      case 'usda':
        return _usda(json['fdcId'], json['portions'], json['per100g'], json['portionId'], count);
      case 'web':
        final base = Nutrients.fromJson(json['base']);
        if (base == null || !_countOk(count)) return null;
        return ServingInfo.web(base: base, count: count!);
      default:
        return null;
    }
  }

  /// A food from the lookup response (or a Siri entry, which carries the same
  /// fields). [looked] is the food's own looked-up nutrients, the base for a
  /// web food.
  static ServingInfo? fromServerItem(Map item, Nutrients looked) {
    switch (item['source']) {
      case 'usda':
        final serving = item['serving'];
        if (serving is! Map) return null;
        return _usda(item['fdcId'], item['portions'], item['per100g'], serving['portionId'],
            _num(serving['count']));
      case 'web':
        return ServingInfo.web(base: looked);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ServingInfo &&
      other.source == source &&
      other.fdcId == fdcId &&
      _listEquals(other.portions, portions) &&
      other.per100g == per100g &&
      other.base == base &&
      other.portionId == portionId &&
      other.count == count;

  @override
  int get hashCode =>
      Object.hash(source, fdcId, Object.hashAll(portions), per100g, base, portionId, count);

  static bool _listEquals(List<ServingPortion> a, List<ServingPortion> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
