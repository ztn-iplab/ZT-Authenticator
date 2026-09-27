import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class ZtIamColors {
  // Palette of the PoIA prototype relying party (app/static/style.css):
  // cream page, warm white panels, teal actions, near-black ink.
  static const Color background = Color(0xFFF4EFE6); // --bg
  static const Color surface = Color(0xFFFFFDF8); // sign-intent modal
  static const Color card = Color(0xFFFBF6EE); // intent and amount panels
  static const Color input = Color(0xFFFFFFFF); // --panel
  static const Color inputBorder = Color(0xFFC6DCE0);
  static const Color textPrimary = Color(0xFF000000);
  static const Color textSecondary = Color(0xFF1E1A16); // --ink
  static const Color textMuted = Color(0xFF1E1A16); // --ink, for readability
  static const Color accentBlue = Color(0xFF0F5B6A); // --accent
  static const Color accentBlueDark = Color(0xFF0A3F49); // --accent-dark
  static const Color accentGreen = Color(0xFF20816C); // positive / recipient
  static const Color accentGreenDark = Color(0xFF185C3D);
  static const Color accentSoft = Color(0xFF0F5B6A);
  static const Color accentSoftMuted = Color(0xFFC6DCE0);
  static const Color divider = Color(0xFFE4D8C8); // --border
  static const Color danger = Color(0xFFB83A3A); // --danger

  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [Color(0xFFFFF7ED), Color(0xFFF4EFE6)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

ThemeData ztIamTheme() {
  final base = ThemeData.light();
  return ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: ZtIamColors.background,
    colorScheme: const ColorScheme.light(
      primary: ZtIamColors.accentBlue,
      secondary: ZtIamColors.accentGreen,
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
    textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme).apply(
      bodyColor: ZtIamColors.textPrimary,
      displayColor: ZtIamColors.textPrimary,
    ),
    primaryTextTheme: GoogleFonts.spaceGroteskTextTheme(base.primaryTextTheme).apply(
      bodyColor: ZtIamColors.textPrimary,
      displayColor: ZtIamColors.textPrimary,
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
      contentTextStyle: TextStyle(color: ZtIamColors.textPrimary),
    ),
    cardTheme: const CardThemeData(
      color: ZtIamColors.card,
      margin: EdgeInsets.zero,
      elevation: 0,
    ),
  );
}
