import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

@immutable
class InstallerVisualTokens extends ThemeExtension<InstallerVisualTokens> {
  const InstallerVisualTokens({
    required this.backgroundBase,
    required this.backgroundAccentStart,
    required this.backgroundAccentEnd,
    required this.panelColor,
    required this.panelBorder,
    required this.panelHighlight,
    required this.mutedForeground,
    required this.footerForeground,
    required this.primaryGradient,
    required this.progressGradient,
    required this.panelRadius,
    required this.panelBlur,
    required this.screenPadding,
  });

  final Color backgroundBase;
  final Color backgroundAccentStart;
  final Color backgroundAccentEnd;
  final Color panelColor;
  final Color panelBorder;
  final Color panelHighlight;
  final Color mutedForeground;
  final Color footerForeground;
  final Gradient primaryGradient;
  final Gradient progressGradient;
  final double panelRadius;
  final double panelBlur;
  final EdgeInsets screenPadding;

  @override
  InstallerVisualTokens copyWith({
    Color? backgroundBase,
    Color? backgroundAccentStart,
    Color? backgroundAccentEnd,
    Color? panelColor,
    Color? panelBorder,
    Color? panelHighlight,
    Color? mutedForeground,
    Color? footerForeground,
    Gradient? primaryGradient,
    Gradient? progressGradient,
    double? panelRadius,
    double? panelBlur,
    EdgeInsets? screenPadding,
  }) {
    return InstallerVisualTokens(
      backgroundBase: backgroundBase ?? this.backgroundBase,
      backgroundAccentStart:
          backgroundAccentStart ?? this.backgroundAccentStart,
      backgroundAccentEnd: backgroundAccentEnd ?? this.backgroundAccentEnd,
      panelColor: panelColor ?? this.panelColor,
      panelBorder: panelBorder ?? this.panelBorder,
      panelHighlight: panelHighlight ?? this.panelHighlight,
      mutedForeground: mutedForeground ?? this.mutedForeground,
      footerForeground: footerForeground ?? this.footerForeground,
      primaryGradient: primaryGradient ?? this.primaryGradient,
      progressGradient: progressGradient ?? this.progressGradient,
      panelRadius: panelRadius ?? this.panelRadius,
      panelBlur: panelBlur ?? this.panelBlur,
      screenPadding: screenPadding ?? this.screenPadding,
    );
  }

  @override
  InstallerVisualTokens lerp(
    ThemeExtension<InstallerVisualTokens>? other,
    double t,
  ) {
    if (other is! InstallerVisualTokens) {
      return this;
    }

    return InstallerVisualTokens(
      backgroundBase: Color.lerp(backgroundBase, other.backgroundBase, t)!,
      backgroundAccentStart: Color.lerp(
        backgroundAccentStart,
        other.backgroundAccentStart,
        t,
      )!,
      backgroundAccentEnd: Color.lerp(
        backgroundAccentEnd,
        other.backgroundAccentEnd,
        t,
      )!,
      panelColor: Color.lerp(panelColor, other.panelColor, t)!,
      panelBorder: Color.lerp(panelBorder, other.panelBorder, t)!,
      panelHighlight: Color.lerp(panelHighlight, other.panelHighlight, t)!,
      mutedForeground: Color.lerp(mutedForeground, other.mutedForeground, t)!,
      footerForeground: Color.lerp(
        footerForeground,
        other.footerForeground,
        t,
      )!,
      primaryGradient: t < 0.5 ? primaryGradient : other.primaryGradient,
      progressGradient: t < 0.5 ? progressGradient : other.progressGradient,
      panelRadius: lerpDouble(panelRadius, other.panelRadius, t)!,
      panelBlur: lerpDouble(panelBlur, other.panelBlur, t)!,
      screenPadding: EdgeInsets.lerp(screenPadding, other.screenPadding, t)!,
    );
  }
}

@immutable
class InstallerMotionTokens extends ThemeExtension<InstallerMotionTokens> {
  const InstallerMotionTokens({
    required this.fast,
    required this.medium,
    required this.slow,
    required this.cinematic,
    required this.stagger,
    required this.enterCurve,
    required this.exitCurve,
    required this.emphasisCurve,
    required this.particleTravel,
    required this.dropdownLift,
    required this.crystalSpread,
  });

  final Duration fast;
  final Duration medium;
  final Duration slow;
  final Duration cinematic;
  final Duration stagger;
  final Curve enterCurve;
  final Curve exitCurve;
  final Curve emphasisCurve;
  final double particleTravel;
  final double dropdownLift;
  final double crystalSpread;

  @override
  InstallerMotionTokens copyWith({
    Duration? fast,
    Duration? medium,
    Duration? slow,
    Duration? cinematic,
    Duration? stagger,
    Curve? enterCurve,
    Curve? exitCurve,
    Curve? emphasisCurve,
    double? particleTravel,
    double? dropdownLift,
    double? crystalSpread,
  }) {
    return InstallerMotionTokens(
      fast: fast ?? this.fast,
      medium: medium ?? this.medium,
      slow: slow ?? this.slow,
      cinematic: cinematic ?? this.cinematic,
      stagger: stagger ?? this.stagger,
      enterCurve: enterCurve ?? this.enterCurve,
      exitCurve: exitCurve ?? this.exitCurve,
      emphasisCurve: emphasisCurve ?? this.emphasisCurve,
      particleTravel: particleTravel ?? this.particleTravel,
      dropdownLift: dropdownLift ?? this.dropdownLift,
      crystalSpread: crystalSpread ?? this.crystalSpread,
    );
  }

  @override
  InstallerMotionTokens lerp(
    ThemeExtension<InstallerMotionTokens>? other,
    double t,
  ) {
    if (other is! InstallerMotionTokens) {
      return this;
    }

    return InstallerMotionTokens(
      fast: Duration(
        microseconds: lerpDouble(
          fast.inMicroseconds,
          other.fast.inMicroseconds,
          t,
        )!.round(),
      ),
      medium: Duration(
        microseconds: lerpDouble(
          medium.inMicroseconds,
          other.medium.inMicroseconds,
          t,
        )!.round(),
      ),
      slow: Duration(
        microseconds: lerpDouble(
          slow.inMicroseconds,
          other.slow.inMicroseconds,
          t,
        )!.round(),
      ),
      cinematic: Duration(
        microseconds: lerpDouble(
          cinematic.inMicroseconds,
          other.cinematic.inMicroseconds,
          t,
        )!.round(),
      ),
      stagger: Duration(
        microseconds: lerpDouble(
          stagger.inMicroseconds,
          other.stagger.inMicroseconds,
          t,
        )!.round(),
      ),
      enterCurve: t < 0.5 ? enterCurve : other.enterCurve,
      exitCurve: t < 0.5 ? exitCurve : other.exitCurve,
      emphasisCurve: t < 0.5 ? emphasisCurve : other.emphasisCurve,
      particleTravel: lerpDouble(particleTravel, other.particleTravel, t)!,
      dropdownLift: lerpDouble(dropdownLift, other.dropdownLift, t)!,
      crystalSpread: lerpDouble(crystalSpread, other.crystalSpread, t)!,
    );
  }
}

extension InstallerThemeContext on BuildContext {
  InstallerVisualTokens get installerVisuals =>
      Theme.of(this).extension<InstallerVisualTokens>()!;

  InstallerMotionTokens get installerMotion =>
      Theme.of(this).extension<InstallerMotionTokens>()!;
}

class AppTheme {
  static const Color _darkBase = Color(0xFF14121B);
  static const Color _darkPanel = Color(0x99211E28);
  static const Color _darkPanelBorder = Color(0x33494455);
  static const Color _darkPrimary = Color(0xFFCCBDFF);
  static const Color _darkPrimaryStrong = Color(0xFF7047EB);
  static const Color _darkPrimaryDeep = Color(0xFF4D13C8);
  static const Color _darkSecondary = Color(0xFFFFB779);
  static const Color _darkTertiary = Color(0xFF00DAF3);

  static const Color _lightBase = Color(0xFFF8F9FF);
  static const Color _lightPanel = Color(0xD9FFFFFF);
  static const Color _lightPanelBorder = Color(0x3D7870AA);
  static const Color _lightPrimary = Color(0xFF7E68F8);
  static const Color _lightPrimaryStrong = Color(0xFF9D6BFF);
  static const Color _lightPrimaryDeep = Color(0xFF6F48E8);
  static const Color _lightSecondary = Color(0xFFFFB3BE);
  static const Color _lightTertiary = Color(0xFF3ABEF4);

  static const InstallerMotionTokens _motion = InstallerMotionTokens(
    fast: Duration(milliseconds: 180),
    medium: Duration(milliseconds: 320),
    slow: Duration(milliseconds: 560),
    cinematic: Duration(milliseconds: 760),
    stagger: Duration(milliseconds: 80),
    enterCurve: Cubic(0.2, 0.0, 0.0, 1.0),
    exitCurve: Cubic(0.4, 0.0, 1.0, 1.0),
    emphasisCurve: Cubic(0.25, 0.1, 0.25, 1.0),
    particleTravel: 56,
    dropdownLift: 18,
    crystalSpread: 28,
  );

  static ThemeData get lightTheme {
    const visuals = InstallerVisualTokens(
      backgroundBase: _lightBase,
      backgroundAccentStart: Color(0xFFECE7FF),
      backgroundAccentEnd: Color(0xFFDFF5FF),
      panelColor: _lightPanel,
      panelBorder: _lightPanelBorder,
      panelHighlight: Color(0x80FFFFFF),
      mutedForeground: Color(0xFF625C73),
      footerForeground: Color(0x80736E87),
      primaryGradient: LinearGradient(
        colors: [_lightPrimaryStrong, _lightPrimaryDeep],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ),
      progressGradient: LinearGradient(
        colors: [_lightPrimaryStrong, _lightTertiary],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ),
      panelRadius: 28,
      panelBlur: 20,
      screenPadding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
    );

    final scheme = const ColorScheme.light(
      primary: _lightPrimary,
      onPrimary: Colors.white,
      secondary: _lightSecondary,
      tertiary: _lightTertiary,
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF241F38),
      outline: Color(0x807870AA),
      outlineVariant: Color(0x337870AA),
      error: Color(0xFFBE2135),
      onError: Colors.white,
    );

    return _baseTheme(
      brightness: Brightness.light,
      scheme: scheme,
      visuals: visuals,
      cardColor: const Color(0xCCFFFFFF),
      scaffoldBackgroundColor: visuals.backgroundBase,
    );
  }

  static ThemeData get darkTheme {
    const visuals = InstallerVisualTokens(
      backgroundBase: _darkBase,
      backgroundAccentStart: Color(0xFF201733),
      backgroundAccentEnd: Color(0xFF102B33),
      panelColor: _darkPanel,
      panelBorder: _darkPanelBorder,
      panelHighlight: Color(0x22FFFFFF),
      mutedForeground: Color(0xFFCAC3D8),
      footerForeground: Color(0x66948EA1),
      primaryGradient: LinearGradient(
        colors: [_darkPrimaryStrong, _darkPrimaryDeep],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ),
      progressGradient: LinearGradient(
        colors: [_darkPrimaryStrong, _darkTertiary],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ),
      panelRadius: 28,
      panelBlur: 20,
      screenPadding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
    );

    final scheme = const ColorScheme.dark(
      primary: _darkPrimary,
      onPrimary: Color(0xFF1F0060),
      secondary: _darkSecondary,
      tertiary: _darkTertiary,
      surface: Color(0xFF1C1A24),
      onSurface: Color(0xFFE6E0EE),
      outline: Color(0xFF948EA1),
      outlineVariant: Color(0xFF494455),
      error: Color(0xFFFFB4AB),
      onError: Color(0xFF690005),
    );

    return _baseTheme(
      brightness: Brightness.dark,
      scheme: scheme,
      visuals: visuals,
      cardColor: const Color(0xAA211E28),
      scaffoldBackgroundColor: visuals.backgroundBase,
    );
  }

  static ThemeData _baseTheme({
    required Brightness brightness,
    required ColorScheme scheme,
    required InstallerVisualTokens visuals,
    required Color cardColor,
    required Color scaffoldBackgroundColor,
  }) {
    final textTheme = TextTheme(
      displayLarge: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 54,
        fontWeight: FontWeight.w800,
        height: 1.04,
        letterSpacing: -2.0,
      ),
      displayMedium: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 46,
        fontWeight: FontWeight.w800,
        height: 1.08,
        letterSpacing: -1.6,
      ),
      displaySmall: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 38,
        fontWeight: FontWeight.w800,
        height: 1.1,
        letterSpacing: -1.2,
      ),
      headlineLarge: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 34,
        fontWeight: FontWeight.w700,
        height: 1.14,
        letterSpacing: -0.8,
      ),
      headlineMedium: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 30,
        fontWeight: FontWeight.w700,
        height: 1.2,
        letterSpacing: -0.6,
      ),
      headlineSmall: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      titleLarge: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      titleMedium: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      bodyLarge: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 18,
        fontWeight: FontWeight.w400,
        height: 1.55,
      ),
      bodyMedium: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      bodySmall: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 13,
        fontWeight: FontWeight.w500,
        height: 1.4,
        letterSpacing: 0.2,
      ),
      labelLarge: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 14,
        fontWeight: FontWeight.w700,
        height: 1.2,
        letterSpacing: 0.3,
      ),
      labelMedium: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        fontWeight: FontWeight.w700,
        height: 1.1,
        letterSpacing: 1.2,
      ),
      labelSmall: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 11,
        fontWeight: FontWeight.w600,
        height: 1.1,
        letterSpacing: 1.0,
      ),
    ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamily: 'Inter',
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBackgroundColor,
      primaryColor: scheme.primary,
      cardColor: cardColor,
      textTheme: textTheme,
      dividerColor: scheme.outlineVariant.withValues(alpha: 0.4),
      extensions: [visuals, _motion],
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cardColor,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurface,
        ),
      ),
      iconTheme: IconThemeData(color: scheme.primary),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface.withValues(
          alpha: brightness == Brightness.dark ? 0.45 : 0.72,
        ),
        labelStyle: textTheme.bodySmall?.copyWith(
          color: visuals.mutedForeground,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: visuals.mutedForeground.withValues(alpha: 0.85),
        ),
        prefixIconColor: scheme.primary,
        suffixIconColor: visuals.mutedForeground,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 1.2),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.onSurface.withValues(alpha: 0.78),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary.withValues(alpha: 0.45);
          }
          return scheme.outlineVariant.withValues(alpha: 0.7);
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary;
          }
          return scheme.onSurface.withValues(alpha: 0.85);
        }),
      ),
    );
  }
}
