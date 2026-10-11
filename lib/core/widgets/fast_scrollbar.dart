import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Barra de desplazamiento arrastrable para listas largas en móvil (ronda 5).
///
/// Aparece al desplazarse y se puede agarrar para saltar a cualquier punto.
/// La zona táctil del pulgar es más ancha que lo que se dibuja.
///
/// Ronda 8 (H-R8-8): era un `RawScrollbar(interactive: true)`, que agarra el
/// pulgar en cuanto se toca. El pulgar está pegado al borde derecho, justo
/// donde empieza el gesto de "atrás" de Android, y el leve movimiento vertical
/// de ese gesto desplazaba la lista. Ahora el pulgar solo se arrastra con un
/// movimiento vertical claro (`onVerticalDrag*`), que un deslizamiento
/// horizontal desde el borde nunca completa, y sigue pegado al borde.
class FastScrollbar extends StatefulWidget {
  const FastScrollbar({super.key, required this.controller, required this.enabled, required this.child});

  final ScrollController controller;
  final bool enabled;
  final Widget child;

  @override
  State<FastScrollbar> createState() => _FastScrollbarState();
}

class _FastScrollbarState extends State<FastScrollbar> {
  static const double _thickness = 6;
  static const double _edgeMargin = 3;
  static const double _hitWidth = 36;
  static const double _minThumbLength = 56;
  static const Duration _timeToFade = Duration(milliseconds: 1200);

  bool _visible = false;
  bool _dragging = false;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _show() {
    _hideTimer?.cancel();
    if (!_visible) setState(() => _visible = true);
    if (!_dragging) _hideTimer = Timer(_timeToFade, _hide);
  }

  void _hide() {
    if (!mounted || _dragging) return;
    setState(() => _visible = false);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical && n is ScrollUpdateNotification) _show();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final topInset = MediaQuery.viewPaddingOf(context).top + 64;
    const bottomInset = 16.0;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        children: [
          widget.child,
          Positioned(
            top: topInset,
            bottom: bottomInset,
            right: 0,
            width: _hitWidth,
            child: LayoutBuilder(
              builder: (context, constraints) => AnimatedBuilder(
                animation: widget.controller,
                builder: (context, _) => _buildThumb(constraints.maxHeight),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumb(double trackLength) {
    final controller = widget.controller;
    if (!controller.hasClients || !controller.position.hasContentDimensions) return const SizedBox.shrink();
    final position = controller.position;
    final maxExtent = position.maxScrollExtent;
    if (maxExtent <= 0 || trackLength <= 0) return const SizedBox.shrink();

    final viewport = position.viewportDimension;
    final thumbLength = (trackLength * viewport / (viewport + maxExtent)).clamp(_minThumbLength, trackLength);
    final travel = trackLength - thumbLength;
    final fraction = (position.pixels / maxExtent).clamp(0.0, 1.0);

    return Stack(
      children: [
        Positioned(
          top: travel * fraction,
          right: 0,
          width: _hitWidth,
          height: thumbLength,
          child: IgnorePointer(
            ignoring: !_visible,
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                _VerticalOnlyDragRecognizer: GestureRecognizerFactoryWithHandlers<_VerticalOnlyDragRecognizer>(
                  _VerticalOnlyDragRecognizer.new,
                  (r) => r
                    ..onStart = (_) {
                      _dragging = true;
                      _show();
                    }
                    ..onUpdate = (details) {
                      if (travel <= 0) return;
                      final target = (position.pixels + details.delta.dy * maxExtent / travel).clamp(0.0, maxExtent);
                      controller.jumpTo(target);
                    }
                    ..onEnd = (_) {
                      _dragging = false;
                      _show();
                    }
                    ..onCancel = () {
                      _dragging = false;
                      _show();
                    },
                ),
              },
              child: AnimatedOpacity(
                opacity: _visible ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    width: _thickness,
                    margin: const EdgeInsets.only(right: _edgeMargin),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(_thickness / 2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Arrastre vertical que solo gana si el movimiento es claramente vertical
/// (al menos el doble que el horizontal) y se rinde si empieza horizontal: el
/// gesto de "atrás" de Android trae algo de temblor vertical, que a un
/// `VerticalDragGestureRecognizer` normal le bastaba para mover la lista.
class _VerticalOnlyDragRecognizer extends VerticalDragGestureRecognizer {
  _VerticalOnlyDragRecognizer() : super(supportedDevices: null);

  Offset? _downAt;
  bool _gaveUp = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _downAt = event.position;
    _gaveUp = false;
    super.addAllowedPointer(event);
  }

  Offset get _moved => _downAt == null ? Offset.zero : lastPosition.global - _downAt!;

  @override
  void handleEvent(PointerEvent event) {
    if (!_gaveUp && event is PointerMoveEvent && _downAt != null) {
      final moved = event.position - _downAt!;
      final slop = computeHitSlop(event.kind, gestureSettings);
      if (moved.dx.abs() > slop / 2 && moved.dx.abs() >= moved.dy.abs()) {
        _gaveUp = true;
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
        return;
      }
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) {
    final moved = _moved;
    return !_gaveUp &&
        super.hasSufficientGlobalDistanceToAccept(pointerDeviceKind, deviceTouchSlop) &&
        moved.dy.abs() >= 2 * moved.dx.abs();
  }
}
