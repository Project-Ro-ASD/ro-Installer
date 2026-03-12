import 'package:flutter/material.dart';

class AppTheme {
  // Ortak Renkler (Stitch Tasarımı Referanslı)
  static const Color primaryPurple = Color(0xFF8C25F4);
  static const Color accentOrange = Color(0xFFFF7A00);
  static const Color accentBlue = Color(0xFF00C2FF);

  static ThemeData get lightTheme {
    return ThemeData(
      brightness: Brightness.light,
      primaryColor: primaryPurple,
      scaffoldBackgroundColor: const Color(0xFFF7F7F9), // Krem/Açık Gri
      colorScheme: const ColorScheme.light(
        primary: primaryPurple,
        secondary: accentBlue,
        tertiary: accentOrange,
        background: Color(0xFFF7F7F9),
        surface: Colors.white,
        onPrimary: Colors.white,
        onSurface: Colors.black87,
      ),
      fontFamily: 'Inter',
      useMaterial3: true,
      elevatedButtonTheme: _buttonTheme(primaryPurple, Colors.white),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: primaryPurple,
      scaffoldBackgroundColor: const Color(0xFF121212), // Koyu arkaplan
      colorScheme: const ColorScheme.dark(
        primary: primaryPurple,
        secondary: accentBlue,
        tertiary: accentOrange,
        background: Color(0xFF121212),
        surface: Color(0xFF1E1E1E),
        onPrimary: Colors.white,
        onSurface: Colors.white,
      ),
      fontFamily: 'Inter',
      useMaterial3: true,
      elevatedButtonTheme: _buttonTheme(primaryPurple, Colors.white),
    );
  }

  static ElevatedButtonThemeData _buttonTheme(Color bg, Color fg) {
    return ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8.0),
        ),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      ),
    );
  }
}
