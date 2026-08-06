import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/app_icons.dart';

/// Pop-up flotante suave al estilo Spotify Desktop / Móvil.
abstract class AppToast {
  static void show(
    BuildContext context, {
    required String message,
    Widget? leadingIcon,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width >= 768;

    // Ancho fijo de 380px en PC centrado horizontalmente
    final sideMargin = isDesktop ? (size.width - 380) / 2 : 16.0;
    // 120px en PC (96px del reproductor + 24px de elevación), 140px en móvil
    final bottomMargin = isDesktop ? 120.0 : 140.0;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 12,
        margin: EdgeInsets.only(
          bottom: bottomMargin,
          left: sideMargin.clamp(16.0, 2000.0),
          right: sideMargin.clamp(16.0, 2000.0),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: duration,
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leadingIcon ??
                Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    gradient: AppTheme.gradientLiked,
                    borderRadius: BorderRadius.all(Radius.circular(6)),
                  ),
                  child: Icon(AppIcons.bold(SolarIcons.Heart), color: Colors.white, size: 16),
                ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Color(0xFF121212),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            if (actionLabel != null && onAction != null)
              GestureDetector(
                onTap: () {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  onAction();
                },
                child: Padding(
                  padding: const EdgeInsets.only(left: 12.0),
                  child: Text(
                    actionLabel,
                    style: const TextStyle(
                      color: Color(0xFF059669),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
