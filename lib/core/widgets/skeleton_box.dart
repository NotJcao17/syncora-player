import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

/// Un bloque esqueleto animado con efecto shimmer para estados de carga.
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double? height;
  final double borderRadius;
  final EdgeInsetsGeometry? margin;

  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.borderRadius = 8.0,
    this.margin,
  });

bool get _isTestEnv {
  try {
    final name = WidgetsBinding.instance.runtimeType.toString();
    return name.contains('Test') || name.contains('Automated');
  } catch (_) {
    return true;
  }
}

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: AppTheme.surfaceHover,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );

    if (_isTestEnv) return box;

    return box.animate(onPlay: (controller) {
      controller.repeat();
    }).shimmer(
      duration: 1200.ms,
      color: AppTheme.surfaceActive.withValues(alpha: 0.5),
    );
  }
}
