import 'package:flutter/material.dart';

/// CarpeCarb Brand Color Palette
/// A warm, natural color scheme designed for mindful carb tracking
class AppColors {
  AppColors._(); // Private constructor to prevent instantiation

  // Background Colors
  static const Color cream = Color(0xFFF5F1EB);
  static const Color warmWhite = Color(0xFFFFFEF9);

  // Primary Brand Colors - Sage
  static const Color sage = Color(0xFF8FA088);
  static const Color sageLight = Color(0xFFA5B59E);
  static const Color sageDark = Color(0xFF4D6B47);

  // Input / Card Colors
  static const Color inputFill = Color(0xFFF9FAFB);
  static const Color cardWhite = Color(0xFFFFFFFF);

  // Primary Gradient
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [sage, sageLight],
  );

  // Accent Colors
  static const Color terracotta = Color(0xFFD4714E);
  static const Color terracottaLight = Color(0xFFE8967A);

  static const Color honey = Color(0xFFE8A93C);
  static const Color honeyLight = Color(0xFFF2C56B);

  static const Color plum = Color(0xFF7B4F72);

  static const Color sky = Color(0xFF5B8DB8);
  static const Color skyLight = Color(0xFF85AECE);

  // Text Colors
  static const Color ink = Color(0xFF2A2520);
  static const Color charcoal = Color(0xFF3D3530);
  static const Color muted = Color(0xFF8A7D74);

  // UI Colors
  static const Color border = Color(0x142A2520); // rgba(42, 37, 32, 0.08)
  static const Color borderMedium = Color(0x332A2520); // ~20% opacity

  // Dark mode adaptive colors (used in darkTheme ThemeData only)
  static const Color darkBackground = Color(0xFF1A1714);
  static const Color darkSurface = Color(0xFF252019);
  static const Color lightInk = Color(0xFFF5EFE8);
  static const Color lightCharcoal = Color(0xFFDDD4CB);
  static const Color darkMuted = Color(0xFF9A8D84);
  static const Color darkBorder = Color(0x14F5EFE8);       // 8% opacity
  static const Color darkBorderMedium = Color(0x33F5EFE8); // 20% opacity

  // Glass effect colors (Liquid Glass-inspired)
  static const Color glassLight = Color(0x99FFFFFF);       // white 60%
  static const Color glassDark = Color(0x66252019);        // dark surface 40%
  static const Color glassBorderLight = Color(0x33FFFFFF); // white 20%
  static const Color glassBorderDark = Color(0x14F5EFE8);  // light 8%

  // Food category colors. Three of these are close to, but deliberately not,
  // the brand colors above — categorySage is not `sage`, categoryPlum is not
  // `plum`, categorySky is not `sky`. They are named here at their original
  // values so the dots on screen stay exactly as they were.
  static const Color categoryHoney = honey;
  static const Color categorySage = Color(0xFF7D9B76);
  static const Color categoryTerracotta = terracotta;
  static const Color categoryPlum = Color(0xFFB07CC6);
  static const Color categorySky = Color(0xFF5B9BD5);

  // Track behind the daily progress bar in light mode.
  static const Color progressTrack = Color(0xFFE5E7EB);

  // Semantic Colors
  static const Color success = sage;
  static const Color warning = honey;
  static const Color error = terracotta;
  static const Color info = sky;

  // Gradient Definitions
  static const LinearGradient sageGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [sageLight, sageDark],
  );

  static const LinearGradient honeyGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [honeyLight, honey],
  );

  static const LinearGradient terracottaGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [terracottaLight, terracotta],
  );
}

/// Material color swatch for sage (primary color)
/// Used by ThemeData for consistent Material Design integration
const MaterialColor sageSwatch = MaterialColor(
  0xFF8FA088, // Base sage color
  <int, Color>{
    50: Color(0xFFF2F4F1),
    100: Color(0xFFDFE5DC),
    200: Color(0xFFC9D3C5),
    300: Color(0xFFA5B59E),
    400: Color(0xFF9AAB93),
    500: Color(0xFF8FA088), // Primary sage
    600: Color(0xFF7E8F78),
    700: Color(0xFF6B7B65),
    800: Color(0xFF586853),
    900: Color(0xFF3A5235),
  },
);
