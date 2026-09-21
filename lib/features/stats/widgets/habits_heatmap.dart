import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../stats_models.dart';

/// Mapa de hábitos: día de la semana × franja horaria.
///
/// Sale gratis de `listened_at`, que ya se guardaba y no se usaba para nada.
/// Se agrupa en franjas de 3 horas (8 columnas) en vez de 24: con 24 las
/// celdas quedan de 3-4 px en móvil y no se distingue nada.
class HabitsHeatmap extends StatelessWidget {
  final List<HourCell> cells;

  const HabitsHeatmap({super.key, required this.cells});

  /// `EXTRACT(dow)` de Postgres: 0 = domingo. Se muestra empezando en lunes,
  /// que es como se lee una semana aquí.
  static const _dowOrder = [1, 2, 3, 4, 5, 6, 0];
  static const _dowLabels = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
  static const _slotLabels = ['0', '3', '6', '9', '12', '15', '18', '21'];

  @override
  Widget build(BuildContext context) {
    if (cells.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: Text('Sin datos en este periodo', style: TextStyle(color: AppTheme.muted)),
        ),
      );
    }

    // [dow][franja de 3h] -> ms
    final grid = List.generate(7, (_) => List<int>.filled(8, 0));
    for (final c in cells) {
      if (c.dow < 0 || c.dow > 6) continue;
      final slot = (c.hour ~/ 3).clamp(0, 7);
      grid[c.dow][slot] += c.ms;
    }
    final maxMs = grid.fold<int>(0, (m, row) => math.max(m, row.reduce(math.max)));
    if (maxMs == 0) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: Text('Sin datos en este periodo', style: TextStyle(color: AppTheme.muted)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var r = 0; r < 7; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: Text(
                    _dowLabels[r],
                    style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                  ),
                ),
                for (var s = 0; s < 8; s++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Tooltip(
                        message: '${_dowLabels[r]} ${_slotLabels[s]}:00-'
                            '${(int.parse(_slotLabels[s]) + 3) % 24}:00 · '
                            '${formatListeningTime(grid[_dowOrder[r]][s])}',
                        child: AspectRatio(
                          aspectRatio: 1.6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _colorFor(grid[_dowOrder[r]][s], maxMs),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Row(
          children: [
            const SizedBox(width: 18),
            for (final l in _slotLabels)
              Expanded(
                child: Text(
                  l,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.muted, fontSize: 10),
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// Escala de intensidad sobre el acento. La raíz cuadrada comprime el
  /// rango alto: con escala lineal, una sola franja muy intensa deja todas
  /// las demás prácticamente invisibles.
  Color _colorFor(int ms, int maxMs) {
    if (ms == 0) return Colors.white.withValues(alpha: 0.04);
    final t = math.sqrt(ms / maxMs);
    return AppTheme.accent.withValues(alpha: 0.15 + 0.75 * t);
  }
}
