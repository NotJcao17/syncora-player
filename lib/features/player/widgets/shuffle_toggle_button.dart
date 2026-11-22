import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../player_providers.dart';

/// Botón de aleatorio de las cabeceras de álbum, playlist y colecciones.
///
/// Ronda 12: **solo cambia el modo** (normal ↔ aleatorio), como el del
/// reproductor. Antes, si la colección no era la que sonaba, la ponía a
/// reproducir en aleatorio; para eso está el botón de play, que ya respeta el
/// modo (empieza en una canción al azar si está activo).
class ShuffleToggleButton extends ConsumerWidget {
  const ShuffleToggleButton({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isShuffle = ref.watch(playerStateProvider.select((s) => s.isShuffle));
    return IconButton(
      key: const Key('shuffle_toggle_button'),
      icon: Padding(
        padding: const EdgeInsets.only(top: 2.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isShuffle ? AppIcons.outline(SolarIcons.Shuffle) : AppIcons.broken(SolarIcons.Shuffle),
              color: isShuffle ? Colors.white : AppTheme.secondary,
              size: size,
            ),
            const SizedBox(height: 2),
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isShuffle ? Colors.white : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
      tooltip: isShuffle ? 'Aleatorio activado' : 'Aleatorio',
      onPressed: () => ref.read(syncoraPlayerControllerProvider.notifier).toggleShuffle(),
    );
  }
}
