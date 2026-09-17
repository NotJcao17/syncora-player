import 'package:flutter/material.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../mixes/mix_models.dart';

/// Portada generada de un mix: color sólido con su ícono, al estilo de
/// "Tus me gusta".
///
/// Solo la usan los mixes que no tienen una imagen que de verdad los
/// represente (ver [SyncoraMix.usesGeneratedCover]).
class MixCover extends StatelessWidget {
  final MixKind kind;
  final double borderRadius;

  const MixCover({super.key, required this.kind, this.borderRadius = 16});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.hasBoundedWidth && constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 160.0;
        return Container(
          decoration: BoxDecoration(
            gradient: AppTheme.gradientMix,
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          child: Center(
            child: Icon(
              AppIcons.bold(kind == MixKind.onRepeat ? SolarIcons.Repeat : SolarIcons.MusicLibrary),
              color: Colors.white,
              size: (side * 0.32).clamp(24.0, 72.0),
            ),
          ),
        );
      },
    );
  }
}
