import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/player/player_providers.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';

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
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final isDesktop = size.width >= 768;
    final keyboardHeight = mediaQuery.viewInsets.bottom;

    double bottomMargin = 110.0;
    if (!isDesktop) {
      if (keyboardHeight > 0) {
        bottomMargin = keyboardHeight + 16.0;
      } else {
        bool isFullscreenPlayer = false;
        try {
          final location = GoRouterState.of(context).matchedLocation;
          isFullscreenPlayer = location == '/player';
        } catch (_) {}

        if (isFullscreenPlayer) {
          bottomMargin = 24.0;
        } else {
          bool hasTrack = false;
          try {
            final container = ProviderScope.containerOf(context, listen: false);
            hasTrack = container.read(currentTrackProvider) != null;
          } catch (_) {}

          if (hasTrack) {
            bottomMargin = 140.0; // flotar dinámicamente sobre el mini-reproductor
          } else {
            bottomMargin = 72.0; // flotar sobre la nav bar móvil
          }
        }
      }
    }

    // Cálculo dinámico de ancho para PC (MainAxisSize.min centrado horizontalmente)
    final textLength = message.length + (actionLabel?.length ?? 0);
    final calculatedWidth = (textLength * 8.5 + 80.0).clamp(200.0, (size.width - 40.0).clamp(200.0, 600.0));

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 12,
        width: isDesktop ? calculatedWidth : null,
        margin: isDesktop
            ? EdgeInsets.only(bottom: bottomMargin)
            : EdgeInsets.only(bottom: bottomMargin, left: 16.0, right: 16.0),
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
