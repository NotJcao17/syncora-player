import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player_models.dart';

/// Qué hace un deslizamiento del mini reproductor al soltarlo.
enum SwipeSkipAction { none, next, previous }

/// Deslizar hacia los lados cambia de canción, como en Spotify: a la
/// izquierda la siguiente, a la derecha la anterior. Lo usan el mini
/// reproductor móvil (portada y título) y la portada del reproductor a
/// pantalla completa.
///
/// Para que no salte sin querer:
/// - el gesto solo gana si el dedo se mueve primero en horizontal (el
///   reconocedor de arrastre horizontal exige el *touch slop*; un toque o un
///   arrastre vertical no cuentan);
/// - hay que llevar la canción al menos [commitFraction] del ancho, o
///   [flingFraction] con un lanzamiento rápido; un roce rápido corto no basta;
/// - si no hay canción en esa dirección, el contenido se resiste y vuelve.
class SwipeToSkip extends StatefulWidget {
  const SwipeToSkip({
    super.key,
    required this.current,
    required this.previous,
    required this.next,
    required this.itemBuilder,
    required this.onNext,
    required this.onPrevious,
    this.onTap,
    required this.layoutBuilder,
    this.clip = true,
  });

  /// Recortar al área. El reproductor a pantalla completa lo apaga para no
  /// cortar el brillo de la portada; las vecinas entran desde el borde de la
  /// pantalla.
  final bool clip;

  final SyncoraTrack current;
  final SyncoraTrack? previous;
  final SyncoraTrack? next;

  /// Dibuja la parte que se desliza de una pista (portada, título...).
  /// [isCurrent] es `true` solo para la que está al centro.
  final Widget Function(BuildContext context, SyncoraTrack track, bool isCurrent) itemBuilder;

  /// Arma lo que rodea a [swipeArea] (la zona que se mueve); lo que quede
  /// fuera, como los botones, no se desplaza.
  final Widget Function(BuildContext context, Widget swipeArea) layoutBuilder;

  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback? onTap;

  /// Distancia mínima (fracción del ancho de la zona) para cambiar.
  static const double commitFraction = 0.35;

  /// Distancia mínima con un lanzamiento rápido.
  static const double flingFraction = 0.2;

  /// Velocidad (px/s) que cuenta como lanzamiento.
  static const double flingVelocity = 900;

  /// Decide qué hacer al soltar, a partir del desplazamiento [dx] (negativo =
  /// hacia la izquierda), la velocidad horizontal [velocity] y el [width] de
  /// la zona. Pura, para poder probarla.
  static SwipeSkipAction decide({
    required double dx,
    required double velocity,
    required double width,
    required bool hasPrevious,
    required bool hasNext,
  }) {
    if (width <= 0) return SwipeSkipAction.none;
    final fraction = dx.abs() / width;
    final sameDirectionFling = velocity.abs() >= flingVelocity && velocity.sign == dx.sign;
    final committed = fraction >= commitFraction || (fraction >= flingFraction && sameDirectionFling);
    if (!committed) return SwipeSkipAction.none;
    if (dx < 0 && hasNext) return SwipeSkipAction.next;
    if (dx > 0 && hasPrevious) return SwipeSkipAction.previous;
    return SwipeSkipAction.none;
  }

  @override
  State<SwipeToSkip> createState() => _SwipeToSkipState();
}

class _SwipeToSkipState extends State<SwipeToSkip> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController.unbounded(vsync: this)..addListener(_onTick);
  double _dx = 0;
  double _width = 1;
  bool _pastThreshold = false;

  /// La pista que el gesto ya dejó al centro mientras el controlador termina
  /// de cambiar (si se pintara `current` un fotograma, "rebotaría").
  SyncoraTrack? _committed;
  Timer? _committedTimeout;

  void _onTick() => setState(() => _dx = _anim.value);

  @override
  void didUpdateWidget(covariant SwipeToSkip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_committed != null && widget.current.id != oldWidget.current.id) {
      _committed = null;
      _committedTimeout?.cancel();
    }
  }

  @override
  void dispose() {
    _committedTimeout?.cancel();
    _anim.dispose();
    super.dispose();
  }

  bool get _hasPrevious => widget.previous != null;
  bool get _hasNext => widget.next != null;

  void _onDragStart(DragStartDetails _) {
    _anim.stop();
    _pastThreshold = false;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    var delta = d.delta.dx;
    final towardsMissing = (_dx + delta > 0 && !_hasPrevious) || (_dx + delta < 0 && !_hasNext);
    if (towardsMissing) delta *= 0.3; // Resistencia: no hay canción de ese lado.
    setState(() => _dx = (_dx + delta).clamp(-_width, _width));

    final past = _dx.abs() / _width >= SwipeToSkip.commitFraction && !towardsMissing;
    if (past && !_pastThreshold) HapticFeedback.selectionClick();
    _pastThreshold = past;
  }

  Future<void> _onDragEnd(DragEndDetails d) async {
    final action = SwipeToSkip.decide(
      dx: _dx,
      velocity: d.velocity.pixelsPerSecond.dx,
      width: _width,
      hasPrevious: _hasPrevious,
      hasNext: _hasNext,
    );
    if (action == SwipeSkipAction.none) {
      await _animateTo(0, const Duration(milliseconds: 220), Curves.easeOutCubic);
      return;
    }

    final target = action == SwipeSkipAction.next ? -_width : _width;
    final incoming = action == SwipeSkipAction.next ? widget.next! : widget.previous!;
    await _animateTo(target, const Duration(milliseconds: 180), Curves.easeOutCubic);
    if (!mounted) return;
    setState(() {
      _committed = incoming;
      _dx = 0;
    });
    _anim.value = 0;
    // Si el controlador ignoró el cambio (estaba en otra transición), se
    // vuelve a la pista real en vez de quedarse mostrando la que no suena.
    _committedTimeout?.cancel();
    _committedTimeout = Timer(const Duration(seconds: 2), () {
      if (mounted && _committed != null) setState(() => _committed = null);
    });
    if (action == SwipeSkipAction.next) {
      widget.onNext();
    } else {
      widget.onPrevious();
    }
  }

  Future<void> _animateTo(double target, Duration duration, Curve curve) {
    _anim.value = _dx;
    return _anim.animateTo(target, duration: duration, curve: curve);
  }

  @override
  Widget build(BuildContext context) {
    final center = _committed ?? widget.current;
    // Con la pista ya cambiada en pantalla, los vecinos de `widget` son los de
    // la vieja: no se dibujan hasta que el controlador se ponga al día.
    final showNeighbours = _committed == null;

    final swipeArea = LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth > 0 ? constraints.maxWidth : 1;
        final progress = (_dx.abs() / _width).clamp(0.0, 1.0);
        final stack = Stack(
          clipBehavior: Clip.none,
          children: [
            Opacity(
              opacity: 1 - progress * 0.6,
              child: Transform.translate(offset: Offset(_dx, 0), child: widget.itemBuilder(context, center, true)),
            ),
            if (showNeighbours && _dx > 0 && widget.previous != null)
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(_dx - _width, 0),
                  child: widget.itemBuilder(context, widget.previous!, false),
                ),
              ),
            if (showNeighbours && _dx < 0 && widget.next != null)
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(_dx + _width, 0),
                  child: widget.itemBuilder(context, widget.next!, false),
                ),
              ),
          ],
        );
        return widget.clip ? ClipRect(child: stack) : stack;
      },
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: () => _animateTo(0, const Duration(milliseconds: 220), Curves.easeOutCubic),
      child: widget.layoutBuilder(context, swipeArea),
    );
  }
}
