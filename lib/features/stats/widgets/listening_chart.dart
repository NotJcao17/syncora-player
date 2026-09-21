import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../stats_models.dart';

/// Gráfico de minutos escuchados: puntos conectados sobre un área
/// degradada.
///
/// `CustomPainter` en vez de una librería de gráficos: son ~200 líneas, no
/// suma una dependencia al bundle, y encaja con el tema oscuro monocromático
/// sin pelearse con los estilos por defecto de nadie.
///
/// La serie llega ya agrupada desde el servidor (o desde `StatsCalculator` en
/// modo local) con el bucket que corresponda al periodo: por día en 7 y 30
/// días, por semana en 3 meses, por mes en las ventanas largas.
class ListeningChart extends StatefulWidget {
  final List<SeriesPoint> series;
  final StatsBucket bucket;

  const ListeningChart({super.key, required this.series, required this.bucket});

  @override
  State<ListeningChart> createState() => _ListeningChartState();
}

class _ListeningChartState extends State<ListeningChart> {
  /// Punto resaltado por toque (móvil) o puntero (escritorio).
  int? _activeIndex;

  @override
  Widget build(BuildContext context) {
    final series = widget.series;
    if (series.isEmpty) {
      return const SizedBox(
        height: 180,
        child: Center(
          child: Text('Sin datos en este periodo', style: TextStyle(color: AppTheme.muted)),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        const height = 200.0;

        void updateFromDx(double dx) {
          final i = _indexForDx(dx, width, series.length);
          if (i != _activeIndex) setState(() => _activeIndex = i);
        }

        return MouseRegion(
          onHover: (e) => updateFromDx(e.localPosition.dx),
          onExit: (_) => setState(() => _activeIndex = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => updateFromDx(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => updateFromDx(d.localPosition.dx),
            onHorizontalDragEnd: (_) => setState(() => _activeIndex = null),
            child: SizedBox(
              height: height,
              width: width,
              child: CustomPaint(
                painter: _ChartPainter(
                  series: series,
                  bucket: widget.bucket,
                  activeIndex: _activeIndex,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static int _indexForDx(double dx, double width, int count) {
    if (count <= 1) return 0;
    const padLeft = _ChartPainter.padLeft;
    const padRight = _ChartPainter.padRight;
    final usable = width - padLeft - padRight;
    if (usable <= 0) return 0;
    final rel = ((dx - padLeft) / usable).clamp(0.0, 1.0);
    return (rel * (count - 1)).round();
  }
}

class _ChartPainter extends CustomPainter {
  final List<SeriesPoint> series;
  final StatsBucket bucket;
  final int? activeIndex;

  static const double padLeft = 8;
  static const double padRight = 8;
  static const double padTop = 16;
  static const double padBottom = 28;

  _ChartPainter({required this.series, required this.bucket, this.activeIndex});

  @override
  void paint(Canvas canvas, Size size) {
    final maxMs = series.fold<int>(0, (m, p) => math.max(m, p.ms));
    // Evita dividir por cero y que una serie toda a cero pinte la línea
    // pegada al borde superior.
    final scaleMax = maxMs == 0 ? 1 : maxMs;

    final chartW = size.width - padLeft - padRight;
    final chartH = size.height - padTop - padBottom;

    Offset pointAt(int i) {
      final x = series.length == 1
          ? padLeft + chartW / 2
          : padLeft + chartW * (i / (series.length - 1));
      final y = padTop + chartH * (1 - series[i].ms / scaleMax);
      return Offset(x, y);
    }

    // Rejilla horizontal discreta: tres líneas, sin etiquetas de eje Y (el
    // número exacto se lee en el tooltip, y así el gráfico respira).
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = padTop + chartH * (i / 2);
      canvas.drawLine(Offset(padLeft, y), Offset(size.width - padRight, y), gridPaint);
    }

    final points = [for (var i = 0; i < series.length; i++) pointAt(i)];

    // Área bajo la curva.
    final areaPath = Path()..moveTo(points.first.dx, padTop + chartH);
    for (final p in points) {
      areaPath.lineTo(p.dx, p.dy);
    }
    areaPath
      ..lineTo(points.last.dx, padTop + chartH)
      ..close();
    canvas.drawPath(
      areaPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppTheme.accent.withValues(alpha: 0.35),
            AppTheme.accent.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, padTop, size.width, chartH)),
    );

    // Línea.
    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      linePath.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = AppTheme.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Puntos. Con muchas fechas (30 días) dibujarlos todos ensucia, así que
    // solo se marcan cuando caben.
    if (series.length <= 14) {
      for (final p in points) {
        canvas.drawCircle(p, 3.5, Paint()..color = AppTheme.background);
        canvas.drawCircle(
          p,
          3.5,
          Paint()
            ..color = AppTheme.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }

    _paintAxisLabels(canvas, size, points);

    final active = activeIndex;
    if (active != null && active >= 0 && active < series.length) {
      _paintTooltip(canvas, size, points[active], series[active]);
    }
  }

  /// Etiquetas del eje X: primera, última y alguna intermedia. Poner una por
  /// punto es ilegible en móvil con 30 días.
  void _paintAxisLabels(Canvas canvas, Size size, List<Offset> points) {
    final idx = <int>{0, series.length - 1};
    if (series.length >= 5) idx.add(series.length ~/ 2);
    if (series.length >= 9) {
      idx..add(series.length ~/ 4)..add(series.length * 3 ~/ 4);
    }

    for (final i in idx) {
      final label = _labelFor(series[i].t);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(color: AppTheme.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      var dx = points[i].dx - tp.width / 2;
      dx = dx.clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(dx, size.height - padBottom + 8));
    }
  }

  String _labelFor(DateTime t) {
    const meses = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
    return switch (bucket) {
      StatsBucket.day => '${t.day} ${meses[t.month - 1]}',
      StatsBucket.week => '${t.day} ${meses[t.month - 1]}',
      StatsBucket.month => '${meses[t.month - 1]} ${t.year % 100}',
    };
  }

  void _paintTooltip(Canvas canvas, Size size, Offset at, SeriesPoint point) {
    canvas.drawLine(
      Offset(at.dx, padTop),
      Offset(at.dx, padTop + size.height - padTop - padBottom),
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );
    canvas.drawCircle(at, 5, Paint()..color = AppTheme.accent);

    final tp = TextPainter(
      text: TextSpan(children: [
        TextSpan(
          text: '${_labelFor(point.t)}\n',
          style: const TextStyle(color: AppTheme.secondary, fontSize: 10),
        ),
        TextSpan(
          text: formatListeningTime(point.ms),
          style: const TextStyle(
              color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ]),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();

    const pad = 8.0;
    final w = tp.width + pad * 2;
    final h = tp.height + pad * 2;
    var left = at.dx - w / 2;
    left = left.clamp(0.0, size.width - w);
    final top = math.max(0.0, at.dy - h - 12);

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, w, h),
      const Radius.circular(10),
    );
    canvas.drawRRect(rect, Paint()..color = AppTheme.surfaceActive);
    canvas.drawRRect(
      rect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke,
    );
    tp.paint(canvas, Offset(left + pad, top + pad));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.series != series || old.activeIndex != activeIndex || old.bucket != bucket;
}
