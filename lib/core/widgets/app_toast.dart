import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/player/player_providers.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';

/// Pop-up flotante suave al estilo Spotify Desktop / Móvil.
abstract class AppToast {
  static OverlayEntry? _currentEntry;
  static Timer? _timer;

  static void show(
    BuildContext context, {
    required String message,
    Widget? leadingIcon,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    _timer?.cancel();
    _currentEntry?.remove();
    _currentEntry = null;

    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final isDesktop = size.width >= 768;
    final keyboardHeight = mediaQuery.viewInsets.bottom;
    final paddingBottom = mediaQuery.padding.bottom;

    double bottomMargin = 104.0;
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
          bottomMargin = 24.0 + paddingBottom;
        } else {
          bool hasTrack = false;
          try {
            final container = ProviderScope.containerOf(context, listen: false);
            hasTrack = container.read(currentTrackProvider) != null;
          } catch (_) {}

          if (hasTrack) {
            bottomMargin = 140.0 + paddingBottom;
          } else {
            bottomMargin = 80.0 + paddingBottom;
          }
        }
      }
    }

    final overlay = Overlay.of(context, rootOverlay: true);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) {
        return Positioned(
          bottom: bottomMargin,
          left: 0,
          right: 0,
          child: Center(
            child: _ToastWidget(
              message: message,
              leadingIcon: leadingIcon,
              actionLabel: actionLabel,
              onAction: () {
                _dismiss();
                onAction?.call();
              },
              isDesktop: isDesktop,
            ),
          ),
        );
      },
    );

    _currentEntry = entry;
    overlay.insert(entry);

    _timer = Timer(duration, () {
      _dismiss();
    });
  }

  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

class _ToastWidget extends StatelessWidget {
  final String message;
  final Widget? leadingIcon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isDesktop;

  const _ToastWidget({
    required this.message,
    this.leadingIcon,
    this.actionLabel,
    this.onAction,
    required this.isDesktop,
  });

  @override
  Widget build(BuildContext context) {
    Widget defaultIcon;
    final lower = message.toLowerCase();
    if (lower.contains('descarg')) {
      defaultIcon = Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(
          color: Color(0xFF1E2633),
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        child: Icon(AppIcons.bold(SolarIcons.CloudCheck), color: AppTheme.primary, size: 14),
      );
    } else if (lower.contains('conexió') || lower.contains('restaurad')) {
      defaultIcon = Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(
          color: Color(0xFF1E2633),
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        child: Icon(AppIcons.bold(SolarIcons.WiFiRouter), color: const Color(0xFF22C55E), size: 14),
      );
    } else {
      defaultIcon = Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(
          color: Color(0xFF1E2633),
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        child: Icon(AppIcons.bold(SolarIcons.CheckCircle), color: Colors.white, size: 14),
      );
    }

    return Material(
      color: Colors.transparent,
      elevation: 0,
      child: AnimatedOpacity(
        opacity: 1.0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: isDesktop ? 600 : 360,
            minWidth: 180,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leadingIcon != null) ...[
                leadingIcon!,
                const SizedBox(width: 10),
              ] else ...[
                defaultIcon,
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
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: onAction,
                  child: Text(
                    actionLabel!,
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
      ),
    );
  }
}

