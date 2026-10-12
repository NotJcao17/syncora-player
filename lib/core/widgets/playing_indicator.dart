import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Barras de "sonando ahora" para la fila de la canción activa (ronda 8,
/// H-R8-15).
///
/// Antes era `LoadingAnimationWidget.staggeredDotsWave`, una animación a
/// 60 fps que nunca se detenía: con la canción actual visible (el buscador, una
/// playlist) la app dibujaba 60 frames por segundo para 18 px de puntos, y en
/// una GPU integrada eso era 20-30 % con la ventana quieta. Estas barras
/// cambian de altura 5 veces por segundo y se detienen con la app oculta o
/// minimizada.
class PlayingIndicator extends StatefulWidget {
  const PlayingIndicator({super.key, required this.color, this.size = 18});

  final Color color;
  final double size;

  static const Duration step = Duration(milliseconds: 200);

  @override
  State<PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<PlayingIndicator> with WidgetsBindingObserver {
  static const _barCount = 3;
  // Alturas relativas por paso, desfasadas por barra: parecen al azar sin
  // serlo (y no hace falta un generador por fila).
  static const _pattern = [0.35, 0.8, 0.55, 1.0, 0.45, 0.7, 0.3, 0.9];

  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncTimer();

  bool get _visible {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _syncTimer() {
    if (_visible) {
      _timer ??= Timer.periodic(PlayingIndicator.step, (_) {
        if (mounted) setState(() => _step++);
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final barWidth = size / 6;
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < _barCount; i++) ...[
              if (i > 0) SizedBox(width: barWidth * 0.8),
              // Sin interpolar entre pasos: animarlos volvería a los 60 fps.
              Container(
                width: barWidth,
                height: math.max(2, size * _pattern[(_step + i * 3) % _pattern.length]),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(barWidth / 2),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
