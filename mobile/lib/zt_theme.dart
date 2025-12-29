import 'package:flutter/material.dart';

class ZtIamColors {
  static const Color background = Color(0xFF1C1C3A);
  static const Color surface = Color(0xFF212141);
  static const Color card = Color(0xFF2D2F4A);
  static const Color input = Color(0xFF0D1117);
  static const Color inputBorder = Color(0xFF30363D);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFD1D1E0);
  static const Color textMuted = Color(0xFF8B949E);
  static const Color accentBlue = Color(0xFF2962FF);
  static const Color accentBlueDark = Color(0xFF1B47CC);
  static const Color accentGreen = Color(0xFF2E7D32);
  static const Color accentGreenDark = Color(0xFF1B5E20);
  static const Color accentSoft = Color(0xFFB3C7FF);
  static const Color accentSoftMuted = Color(0xFF8FA3FF);
  static const Color divider = Color(0xFF30363D);

  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [Color(0xFF1C1C3A), Color(0xFF212141)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

ThemeData ztIamTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: ZtIamColors.background,
    colorScheme: const ColorScheme.dark(
      primary: ZtIamColors.accentBlue,
      secondary: ZtIamColors.accentGreen,
      background: ZtIamColors.background,
      surface: ZtIamColors.surface,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: ZtIamColors.textPrimary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: ZtIamColors.background,
      foregroundColor: ZtIamColors.textPrimary,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ZtIamColors.input,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: ZtIamColors.inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: ZtIamColors.inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: ZtIamColors.accentBlue),
      ),
    ),
    dividerColor: ZtIamColors.divider,
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: ZtIamColors.accentBlue,
      foregroundColor: Colors.white,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: ZtIamColors.card,
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    cardTheme: const CardThemeData(
      color: ZtIamColors.card,
      margin: EdgeInsets.zero,
      elevation: 0,
    ),
  );
}
