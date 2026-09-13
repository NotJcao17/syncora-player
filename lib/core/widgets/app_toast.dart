import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/player/player_providers.dart';
import '../layout/bottom_chrome_metrics.dart';
import '../theme/app_icons.dart';


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
    if (!context.mounted) return;
    try {
      _timer?.cancel();
      _currentEntry?.remove();
      _currentEntry = null;

      final mediaQuery = MediaQuery.of(context);
      final size = mediaQuery.size;
      final isDesktop = size.width >= 768;
      final keyboardHeight = mediaQuery.viewInsets.bottom;
      final paddingBottom = mediaQuery.padding.bottom;

      // ¿Se ve el chrome inferior del shell desde donde se disparó el aviso?
      //
      // Ronda 3 bis: antes esto se deducía de la ruta de GoRouter ('/player',
      // '/auth'), y por eso un aviso lanzado desde la pantalla de Cola —que se
      // empuja por encima del shell pero no cambia la ruta— se posicionaba
      // como si el mini reproductor estuviera delante, y acababa flotando a
      // media pantalla. Ahora lo declara el propio subárbol.
      bool hasChrome = BottomChromeScope.hasChromeAt(context);
      if (hasChrome) {
        try {
          final location = GoRouterState.of(context).matchedLocation;
          if (location == '/player' || location == '/auth') hasChrome = false;
        } catch (_) {}
      }

      // Alto REAL del chrome, medido por `MeasuredBottomChrome` en el shell
      // (ver `bottom_chrome_metrics.dart`). Estimarlo con constantes es lo que
      // dejaba el aviso montado sobre el mini reproductor cada vez que este
      // cambiaba de alto.
      double chromeHeight = 0;
      bool hasActiveMiniPlayer = false;
      try {
        final container = ProviderScope.containerOf(context, listen: false);
        hasActiveMiniPlayer = container.read(currentTrackProvider) != null;
        chromeHeight = container.read(bottomChromeHeightProvider);
      } catch (_) {}

      double bottomMargin = 104.0;
      if (!isDesktop) {
        if (keyboardHeight > 0) {
          bottomMargin = keyboardHeight + 16.0;
        } else if (!hasChrome) {
          // Ruta a pantalla completa por encima del shell: pegado al borde.
          bottomMargin = 16.0 + paddingBottom;
        } else {
          bottomMargin = chromeHeight + 12.0;
        }
      } else {
        if (!hasChrome) {
          bottomMargin = 24.0;
        } else {
          bottomMargin = hasActiveMiniPlayer ? 104.0 : 32.0;
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
    } catch (_) {}
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
    if (lower.contains('me gusta') || lower.contains('favorit') || lower.contains('like')) {
      defaultIcon = Icon(AppIcons.bold(SolarIcons.Heart), color: Colors.white, size: 16);
    } else if (lower.contains('descarg')) {
      defaultIcon = Icon(AppIcons.bold(SolarIcons.CloudCheck), color: Colors.white, size: 16);
    } else if (lower.contains('cola') || lower.contains('queue')) {
      defaultIcon = Icon(AppIcons.bold(SolarIcons.ListCross), color: Colors.white, size: 16);
    } else if (lower.contains('álbum') || lower.contains('album')) {
      defaultIcon = Icon(AppIcons.bold(SolarIcons.VinylRecord), color: Colors.white, size: 16);
    } else if (lower.contains('playlist') || lower.contains('lista')) {
      defaultIcon = Icon(AppIcons.bold(SolarIcons.MusicNote), color: Colors.white, size: 16);
    } else if (lower.contains('eliminad') || lower.contains('borrad') || lower.contains('quitad')) {
      defaultIcon = Icon(AppIcons.bold(SolarIcons.TrashBinTrash), color: Colors.white, size: 16);
    } else if (lower.contains('conexió') || lower.contains('restaurad') || lower.contains('wifi')) {
      defaultIcon = Icon(AppIcons.bold(SolarIcons.WiFiRouter), color: const Color(0xFF22C55E), size: 16);
    } else if (lower.contains('error') || lower.contains('falló') || lower.contains('no se pudo') || lower.contains('no disponible')) {
      defaultIcon = Icon(AppIcons.bold(SolarIcons.DangerCircle), color: const Color(0xFFEF4444), size: 16);
    } else {
      defaultIcon = Icon(AppIcons.bold(SolarIcons.CheckCircle), color: Colors.white, size: 16);
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
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF2A2A2A),
              width: 1,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
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
                const SizedBox(width: 8),
              ] else ...[
                defaultIcon,
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    decoration: TextDecoration.none,
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
                      color: Color(0xFF22C55E),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      decoration: TextDecoration.none,
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


