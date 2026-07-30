import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  AppTheme._();

  // Color Palette
  static const Color background = Color(0xFF181C27);
  static const Color surface = Color(0xFF1E2633);
  static const Color surfaceHover = Color(0xFF252E3D);
  static const Color surfaceActive = Color(0xFF2C3647);
  static const Color primary = Color(0xFFFFFFFF);
  static const Color secondary = Color(0xFFA0ABBA);
  static const Color muted = Color(0xFF7F8C9D);

  static ThemeData get darkTheme {
    final baseTextTheme = GoogleFonts.plusJakartaSansTextTheme(
      ThemeData.dark().textTheme,
    );

    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: background,
      primaryColor: primary,
      colorScheme: const ColorScheme.dark(
        background: background,
        surface: surface,
        primary: primary,
        secondary: secondary,
        onBackground: primary,
        onSurface: primary,
        onPrimary: background,
        onSecondary: background,
      ),
      cardColor: surface,
      textTheme: baseTextTheme.copyWith(
        displayLarge: baseTextTheme.displayLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.02,
        ),
        displayMedium: baseTextTheme.displayMedium?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.02,
        ),
        displaySmall: baseTextTheme.displaySmall?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.02,
        ),
        headlineLarge: baseTextTheme.headlineLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.02,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.02,
        ),
        headlineSmall: baseTextTheme.headlineSmall?.copyWith(
          color: primary,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.02,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          color: primary,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: baseTextTheme.titleSmall?.copyWith(
          color: secondary,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w400,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(
          color: secondary,
          fontWeight: FontWeight.w400,
        ),
        bodySmall: baseTextTheme.bodySmall?.copyWith(
          color: muted,
          fontWeight: FontWeight.w400,
        ),
        labelLarge: baseTextTheme.labelLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: baseTextTheme.labelMedium?.copyWith(
          color: secondary,
          fontWeight: FontWeight.w500,
        ),
        labelSmall: baseTextTheme.labelSmall?.copyWith(
          color: muted,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}
