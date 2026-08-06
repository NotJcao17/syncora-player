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

    // Floating above bottom bar / mini-player (90px margin)
    final sideMargin = isDesktop ? ((size.width - 380) / 2).clamp(16.0, 2000.0) : 16.0;
    const bottomMargin = 90.0;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 12,
        margin: EdgeInsets.only(
          bottom: bottomMargin,
          left: sideMargin,
          right: sideMargin,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: duration,
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leadingIcon != null) ...[
              leadingIcon,
              const SizedBox(width: 10),
            ] else ...[
              Container(
                width: 24,
                height: 24,
                decoration: const BoxDecoration(
                  gradient: AppTheme.gradientLiked,
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                ),
                child: Icon(AppIcons.bold(SolarIcons.Heart), color: Colors.white, size: 14),
              ),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                message,
                style: const TextStyle(
                  color: Color(0xFF121212),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  onAction();
                },
                child: Text(
                  actionLabel,
                  style: const TextStyle(
                    color: Color(0xFF059669),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
