import 'package:flutter/widgets.dart';

/// Un "+" sin círculo con el trazo de los íconos Solar (1,5 sobre 24, puntas
/// redondeadas). Solar no trae uno suelto (solo `AddCircle` y `AddSquare`), y
/// en el reproductor el círculo lo hacía verse distinto al resto de la fila
/// (ronda 13).
class PlainPlusIcon extends StatelessWidget {
  const PlainPlusIcon({super.key, required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _PlusPainter(color)),
    );
  }
}

class _PlusPainter extends CustomPainter {
  _PlusPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide / 24;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5 * unit
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final c = size.center(Offset.zero);
    final half = 7 * unit;
    canvas.drawLine(c.translate(-half, 0), c.translate(half, 0), paint);
    canvas.drawLine(c.translate(0, -half), c.translate(0, half), paint);
  }

  @override
  bool shouldRepaint(_PlusPainter old) => old.color != color;
}
