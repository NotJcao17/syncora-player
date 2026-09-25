import 'package:flutter/material.dart';
import '../layout/bottom_chrome_metrics.dart';
import '../theme/app_theme.dart';

/// Modal Bottom Sheet personalizado con fondo sólido #1E2633 y handle bar.
class AppBottomSheet extends StatefulWidget {
  final String? title;
  final Widget child;
  final double maxHeightFactor;

  const AppBottomSheet({
    super.key,
    this.title,
    required this.child,
    this.maxHeightFactor = 0.85,
  });

  /// [enableDrag] `false` desactiva el gesto de arrastrar la hoja **entera**
  /// hacia abajo para cerrarla.
  ///
  /// Hace falta cuando el contenido tiene su propio gesto vertical, como la
  /// lista reordenable de la cola: el `VerticalDragGestureRecognizer` que
  /// `showModalBottomSheet` monta alrededor de todo el contenido compite con
  /// los gestos de cada fila.
  ///
  /// **La hoja se sigue pudiendo bajar a mano**: el asa y el título de arriba
  /// siempre llevan su propio arrastre (ronda 3 bis), igual que el reproductor
  /// a pantalla completa. Así conviven el "deslizar para cerrar" de toda la
  /// vida y los gestos del contenido, porque cada uno vive en una zona
  /// distinta de la pantalla.
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget child,
    String? title,
    double maxHeightFactor = 0.85,
    bool enableDrag = true,
  }) {
    final isDesktop = MediaQuery.sizeOf(context).width >= 720;
    if (isDesktop) {
      return showDialog<T>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null) ...[
                  Text(
                    title,
                    style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),

                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppTheme.surfaceHover),
                  const SizedBox(height: 12),
                ],
                Flexible(child: child),
              ],
            ),
          ),
        ),
      );
    }

    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      enableDrag: enableDrag,
      backgroundColor: Colors.transparent,
      // Ronda 4: la hoja sube con el teclado. Sin esto, un campo de texto
      // dentro de la hoja quedaba tapado.
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: AppBottomSheet(
          title: title,
          maxHeightFactor: maxHeightFactor,
          child: child,
        ),
      ),
    );
  }

  static void pop(BuildContext context) {
    if (!context.mounted) return;
    try {
      final isDesktop = MediaQuery.sizeOf(context).width >= 720;
      if (isDesktop) {
        Navigator.of(context, rootNavigator: true).pop();
      } else {
        if (Navigator.canPop(context)) {
          Navigator.of(context).pop();
        }
      }
    } catch (_) {
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    }
  }



  @override
  State<AppBottomSheet> createState() => _AppBottomSheetState();
}

class _AppBottomSheetState extends State<AppBottomSheet> {
  /// Desplazamiento vertical del arrastre en curso sobre la cabecera.
  double _dragOffsetY = 0;

  void _onHeaderDragUpdate(DragUpdateDetails details) {
    // Solo hacia abajo: tirar hacia arriba no hace nada (la hoja ya está en su
    // sitio), igual que en el reproductor a pantalla completa.
    if (details.delta.dy <= 0 && _dragOffsetY <= 0) return;
    setState(() {
      _dragOffsetY = (_dragOffsetY + details.delta.dy).clamp(0.0, 600.0);
    });
  }

  void _onHeaderDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dragOffsetY > 110 || velocity > 350) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _dragOffsetY = 0);
  }

  @override
  Widget build(BuildContext context) {
    // Ronda 4 (H-R4-7): `sizeOf` y no `of`. Con `of`, la hoja entera se
    // reconstruía en cada frame de la animación del teclado.
    final maxHeight = MediaQuery.sizeOf(context).height * widget.maxHeightFactor;

    final header = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onHeaderDragUpdate,
      onVerticalDragEnd: _onHeaderDragEnd,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.muted.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (widget.title != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(
                widget.title!,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            const Divider(height: 1, color: AppTheme.surfaceHover),
          ],
        ],
      ),
    );

    return Transform.translate(
      offset: Offset(0, _dragOffsetY),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: AppTheme.surfaceUpShadow,
        ),
        child: SafeArea(
          top: false,
          // Una hoja modal tapa el mini reproductor y la barra de navegación,
          // así que los avisos disparados desde dentro no deben esquivarlos:
          // sin esto, el aviso de "cola regenerada" aparecía a la altura del
          // chrome, o sea flotando en mitad de la propia hoja.
          child: BottomChromeScope(
            hasChrome: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Flexible(child: widget.child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
