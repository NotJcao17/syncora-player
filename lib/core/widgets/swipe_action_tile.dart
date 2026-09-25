import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Fila deslizable con dos acciones opcionales (ronda 4, H-R4-5 / H-R4-6).
///
/// Sustituye al `Dismissible` de Flutter en las listas de canciones y en la
/// cola, por dos motivos que no se podían arreglar desde fuera de él:
///
/// - **Encolar sin querer al hacer scroll.** El `Dismissible` reclama el
///   gesto horizontal con el mismo umbral (18 px) que el scroll vertical, así
///   que un scroll algo diagonal podía ganarlo; y confirma con un "fling"
///   aunque no se llegue al umbral de distancia. Aquí el deslizar a la derecha
///   **solo puede empezar en el borde izquierdo** de la pantalla, exige el
///   doble de recorrido y que sea claramente más horizontal que vertical, y
///   solo cuenta la distancia (nunca la velocidad).
/// - **"A dismissed Dismissible widget is still part of the tree".** El
///   `Dismissible` se queda en estado "descartado" y revienta si la fila
///   sigue en el árbol al siguiente frame (p. ej. si la cola cambió durante
///   el gesto). Esta fila no tiene ese estado: tras la acción vuelve sola a
///   su sitio si la lista no la quitó.
class SwipeActionTile extends StatefulWidget {
  const SwipeActionTile({
    super.key,
    required this.child,
    this.onSwipeRight,
    this.onSwipeLeft,
    this.rightBackground,
    this.leftBackground,
    this.threshold = 0.35,
    this.rightEdgeFraction = 0.3,
  });

  final Widget child;

  /// Deslizar hacia la derecha (p. ej. agregar a la cola). La fila vuelve a
  /// su sitio después.
  final VoidCallback? onSwipeRight;

  /// Deslizar hacia la izquierda (p. ej. quitar). La fila sale de pantalla y
  /// luego se llama al callback.
  final VoidCallback? onSwipeLeft;

  /// Fondo visible al deslizar a la derecha (queda a la izquierda).
  final Widget? rightBackground;

  /// Fondo visible al deslizar a la izquierda (queda a la derecha).
  final Widget? leftBackground;

  /// Fracción del ancho de la fila a recorrer para confirmar la acción.
  final double threshold;

  /// Fracción del ancho de la pantalla, desde el borde izquierdo, en la que
  /// tiene que apoyarse el dedo para que cuente un deslizar a la derecha.
  final double rightEdgeFraction;

  @override
  State<SwipeActionTile> createState() => _SwipeActionTileState();
}

class _SwipeActionTileState extends State<SwipeActionTile> with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  double _dx = 0;
  double _animFrom = 0;
  double _animTo = 0;
  double _width = 1;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
      ..addListener(() {
        setState(() {
          _dx = _animFrom + (_animTo - _animFrom) * Curves.easeOut.transform(_anim.value);
        });
      });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _animateTo(double target) async {
    _animFrom = _dx;
    _animTo = target;
    await _anim.forward(from: 0);
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_anim.isAnimating) _anim.stop();
    var next = _dx + d.delta.dx;
    final maxRight = widget.onSwipeRight != null ? _width * 0.6 : 0.0;
    final maxLeft = widget.onSwipeLeft != null ? -_width : 0.0;
    next = next.clamp(maxLeft, maxRight);
    if (next != _dx) setState(() => _dx = next);
  }

  Future<void> _onEnd(DragEndDetails _) async {
    final limit = _width * widget.threshold;
    if (_dx >= limit && widget.onSwipeRight != null) {
      HapticFeedback.mediumImpact();
      widget.onSwipeRight!();
      await _animateTo(0);
    } else if (_dx <= -limit && widget.onSwipeLeft != null) {
      HapticFeedback.mediumImpact();
      await _animateTo(-_width);
      if (!mounted) return;
      widget.onSwipeLeft!();
      // Si la lista no quitó esta fila (la acción no aplicó), vuelve a verse.
      if (mounted) setState(() => _dx = 0);
    } else {
      await _animateTo(0);
    }
  }

  void _onCancel() {
    if (_dx != 0) _animateTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final background = _dx > 0 ? widget.rightBackground : (_dx < 0 ? widget.leftBackground : null);

    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth.isFinite ? constraints.maxWidth : screenWidth;
        return RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: {
            EdgeAwareHorizontalDragRecognizer: GestureRecognizerFactoryWithHandlers<EdgeAwareHorizontalDragRecognizer>(
              () => EdgeAwareHorizontalDragRecognizer(debugOwner: this),
              (r) {
                r
                  // `down`: al aceptar, el recorrido previo (el que hizo
                  // falta para distinguirlo del scroll) también mueve la fila,
                  // y queda bajo el dedo en vez de "saltar" el umbral.
                  ..dragStartBehavior = DragStartBehavior.down
                  ..allowRight = widget.onSwipeRight != null
                  ..allowLeft = widget.onSwipeLeft != null
                  ..rightStartMaxX = screenWidth * widget.rightEdgeFraction
                  ..onUpdate = _onUpdate
                  ..onEnd = _onEnd
                  ..onCancel = _onCancel;
              },
            ),
          },
          child: Stack(
            children: [
              // Solo se ve la franja que la fila ya dejó al descubierto: las
              // filas son transparentes, y con el fondo completo detrás su
              // texto se encimaba con el de la fila (ronda 4). Así la etiqueta
              // aparece poco a poco conforme se desliza.
              if (background != null)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: _dx > 0 ? 0 : null,
                  right: _dx < 0 ? 0 : null,
                  width: _dx.abs(),
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: _dx > 0 ? Alignment.centerLeft : Alignment.centerRight,
                      minWidth: _width,
                      maxWidth: _width,
                      child: background,
                    ),
                  ),
                ),
              Transform.translate(offset: Offset(_dx, 0), child: widget.child),
            ],
          ),
        );
      },
    );
  }
}

/// Arrastre horizontal que solo reclama el gesto cuando es claramente
/// deliberado (ver [SwipeActionTile]).
///
/// El scroll vertical acepta al pasar el umbral de toque en el eje Y. Este
/// reconocedor, en cambio, exige:
/// - hacia la derecha: empezar a menos de [rightStartMaxX] del borde
///   izquierdo de la pantalla, recorrer el doble del umbral y que el
///   desplazamiento horizontal sea 2,5 veces el vertical;
/// - hacia la izquierda: el umbral normal y 1,5 veces más horizontal que
///   vertical.
/// Si la dirección no está habilitada, nunca acepta, y el scroll gana solo.
class EdgeAwareHorizontalDragRecognizer extends HorizontalDragGestureRecognizer {
  EdgeAwareHorizontalDragRecognizer({super.debugOwner});

  bool allowRight = false;
  bool allowLeft = false;
  double rightStartMaxX = double.infinity;

  Offset _down = Offset.zero;
  Offset _last = Offset.zero;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _down = event.position;
    _last = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _last = event.position;
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) {
    final delta = _last - _down;
    final dx = delta.dx;
    final dy = delta.dy.abs();
    final slop = computeHitSlop(pointerDeviceKind, gestureSettings);
    if (dx > 0) {
      if (!allowRight || _down.dx > rightStartMaxX) return false;
      return dx > slop * 2 && dx > dy * 2.5;
    }
    if (!allowLeft) return false;
    return -dx > slop && -dx > dy * 1.5;
  }
}
