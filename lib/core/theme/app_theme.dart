import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  AppTheme._();

  // Color Palette (calcada de docs/mockups/js/tailwind-config.js)
  static const Color background = Color(0xFF181C27);
  static const Color bgDark = Color(0xFF121212);
  static const Color surface = Color(0xFF1E2633);
  static const Color surfaceHover = Color(0xFF252E3D);
  static const Color surfaceActive = Color(0xFF2C3647);
  static const Color primary = Color(0xFFFFFFFF);
  static const Color secondary = Color(0xFFA0ABBA);
  static const Color muted = Color(0xFF7F8C9D);
  static const Color accent = Color(0xFF6366F1);
  static const Color error = Color(0xFFB4ABFF); // #ffb4ab (mockup "error")

  // Colores de géneros para "Explorar todo" (search.html mockup)
  static const Color genrePop = Color(0xFF4F46E5); // indigo-600
  static const Color genreHipHop = Color(0xFF047857); // emerald-700
  static const Color genreRock = Color(0xFFBE123C); // rose-700
  static const Color genreElectronic = Color(0xFF1D4ED8); // blue-700

  // Gradiente de "Me Gusta" / Liked Songs (library.html mockup: from-indigo-500 to-purple-600)
  static const LinearGradient gradientLiked = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6366F1), Color(0xFF9333EA)],
  );

  // --- Sombras (calcadas de tailwind-config.js boxShadow) ---
  /// shadow-glow: 0 0 20px rgba(255,255,255,0.15) — botones play, portadas destacadas.
  static const List<BoxShadow> glowShadow = [
    BoxShadow(color: Color(0x26FFFFFF), blurRadius: 20, spreadRadius: 0),
  ];

  /// shadow-glow-high: 0 0 40px rgba(255,255,255,0.3) — portada del reproductor fullscreen.
  static const List<BoxShadow> glowHighShadow = [
    BoxShadow(color: Color(0x4DFFFFFF), blurRadius: 40, spreadRadius: 0),
  ];

  /// Brillo en texto para títulos principales
  static const List<Shadow> textGlow = [
    Shadow(color: Color(0x66FFFFFF), blurRadius: 16, offset: Offset(0, 0)),
  ];

  /// shadow-surface: 0 8px 30px rgba(0,0,0,0.12) — tarjetas elevadas.
  static const List<BoxShadow> surfaceShadow = [
    BoxShadow(color: Color(0x1F000000), blurRadius: 30, offset: Offset(0, 8)),
  ];

  /// shadow-surface-up: 0 -8px 30px rgba(0,0,0,0.12) — hojas inferiores.
  static const List<BoxShadow> surfaceUpShadow = [
    BoxShadow(color: Color(0x1F000000), blurRadius: 30, offset: Offset(0, -8)),
  ];

  /// Mini player móvil: shadow-[0_-4px_20px_rgba(0,0,0,0.3)].
  static const List<BoxShadow> miniPlayerShadow = [
    BoxShadow(color: Color(0x4D000000), blurRadius: 20, offset: Offset(0, -4)),
  ];

  /// Bottom nav móvil: shadow-[0_-8px_20px_rgba(0,0,0,0.3)].
  static const List<BoxShadow> bottomNavShadow = [
    BoxShadow(color: Color(0x4D000000), blurRadius: 20, offset: Offset(0, -8)),
  ];

  static ThemeData get darkTheme {
    final baseTextTheme = GoogleFonts.interTextTheme(
      ThemeData.dark().textTheme,
    );

    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: background,
      primaryColor: primary,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      ),
      colorScheme: const ColorScheme.dark(
        surface: surface,
        primary: primary,
        secondary: secondary,
        onSurface: primary,
        onPrimary: background,
        onSecondary: background,
      ),
      cardColor: surface,
      textTheme: baseTextTheme.copyWith(
        displayLarge: baseTextTheme.displayLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.02,
        ),
        displayMedium: baseTextTheme.displayMedium?.copyWith(
          color: primary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.02,
        ),
        displaySmall: baseTextTheme.displaySmall?.copyWith(
          color: primary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.02,
        ),
        headlineLarge: baseTextTheme.headlineLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.02,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          color: primary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.02,
        ),
        headlineSmall: baseTextTheme.headlineSmall?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.02,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
        ),
        titleSmall: baseTextTheme.titleSmall?.copyWith(
          color: secondary,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w500,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(
          color: secondary,
          fontWeight: FontWeight.w500,
        ),
        bodySmall: baseTextTheme.bodySmall?.copyWith(
          color: muted,
          fontWeight: FontWeight.w500,
        ),
        labelLarge: baseTextTheme.labelLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
        ),
        labelMedium: baseTextTheme.labelMedium?.copyWith(
          color: secondary,
          fontWeight: FontWeight.w600,
        ),
        labelSmall: baseTextTheme.labelSmall?.copyWith(
          color: muted,
          fontWeight: FontWeight.w500,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.white,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        contentTextStyle: const TextStyle(
          color: Color(0xFF121212),
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
        actionTextColor: AppTheme.primary,
      ),
    );
  }
}
