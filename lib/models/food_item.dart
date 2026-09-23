import 'dart:math';

import 'package:flutter/material.dart';

import '../config/app_colors.dart';

enum FoodCategory {
  breakfast,
  lunch,
  dinner,
  snack,
  drink;

  String get label {
    return name[0].toUpperCase() + name.substring(1);
  }

  IconData get icon {
    switch (this) {
      case FoodCategory.breakfast:
        return Icons.egg_alt;
      case FoodCategory.lunch:
        return Icons.lunch_dining;
      case FoodCategory.dinner:
        return Icons.dinner_dining;
      case FoodCategory.snack:
        return Icons.cookie;
      case FoodCategory.drink:
        return Icons.local_cafe;
    }
  }

  Color get color {
    switch (this) {
      case FoodCategory.breakfast:
        return AppColors.categoryHoney;
      case FoodCategory.lunch:
        return AppColors.categorySage;
      case FoodCategory.dinner:
        return AppColors.categoryTerracotta;
      case FoodCategory.snack:
        return AppColors.categoryPlum;
      case FoodCategory.drink:
        return AppColors.categorySky;
    }
  }

  /// Assign category based on time of day
  static FoodCategory fromTime(DateTime time) {
    final hour = time.hour;
    if (hour >= 5 && hour < 11) return FoodCategory.breakfast;
    if (hour >= 11 && hour < 15) return FoodCategory.lunch;
    if (hour >= 15 && hour < 17) return FoodCategory.snack;
    if (hour >= 17 && hour < 21) return FoodCategory.dinner;
    return FoodCategory.snack; // late night = snack
  }

  static FoodCategory fromString(String value) {
    return FoodCategory.values.firstWhere(
      (c) => c.name == value,
      orElse: () => FoodCategory.snack,
    );
  }
}

class FoodItem {
  final String id;
  final String name;
  final double carbs;
  final double? protein;
  final double? fat;
  final double? fiber;
  final double? calories;
  final String? details;
  final List<String> citations;
  final DateTime loggedAt;
  final FoodCategory category;
  final bool isManualEntry;

  FoodItem({
    String? id,
    required this.name,
    required this.carbs,
    this.protein,
    this.fat,
    this.fiber,
    this.calories,
    this.details,
    this.citations = const [],
    this.isManualEntry = false,
    DateTime? loggedAt,
    FoodCategory? category,
  })  : id = id ?? _generateId(),
        loggedAt = loggedAt ?? DateTime.now(),
        category = category ?? FoodCategory.fromTime(loggedAt ?? DateTime.now());

  /// Generates a random UUID v4 without external dependencies.
  static String _generateId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  bool get hasMacros => protein != null || fat != null || fiber != null || calories != null;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'carbs': carbs,
      'loggedAt': loggedAt.toIso8601String(),
      'category': category.name,
      if (protein != null) 'protein': protein,
      if (fat != null) 'fat': fat,
      if (fiber != null) 'fiber': fiber,
      if (calories != null) 'calories': calories,
      if (details != null) 'details': details,
      if (citations.isNotEmpty) 'citations': citations,
      if (isManualEntry) 'isManualEntry': true,
    };
  }

  static DateTime? _parseLoggedAt(dynamic value, String name) {
    if (value == null) {
      debugPrint('FoodItem: missing loggedAt for "$name", defaulting to now');
      return null;
    }
    final parsed = DateTime.tryParse(value as String);
    if (parsed == null) {
      debugPrint('FoodItem: malformed loggedAt "$value" for "$name", defaulting to now');
    }
    return parsed;
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  factory FoodItem.fromJson(Map<String, dynamic> json) {
    final loggedAt = _parseLoggedAt(json['loggedAt'], json['name'] as String);
    return FoodItem(
      id: json['id'] as String?, // null → auto-generate for legacy items
      name: json['name'] as String,
      carbs: _parseDouble(json['carbs']) ?? 0.0,
      protein: _parseDouble(json['protein']),
      fat: _parseDouble(json['fat']),
      fiber: _parseDouble(json['fiber']),
      calories: _parseDouble(json['calories']),
      details: json['details'] as String?,
      citations: json['citations'] is List
          ? (json['citations'] as List).whereType<String>().toList()
          : const [],
      loggedAt: loggedAt,
      isManualEntry: json['isManualEntry'] as bool? ?? false,
      category: json['category'] != null
          ? FoodCategory.fromString(json['category'] as String)
          : null,
    );
  }
}
