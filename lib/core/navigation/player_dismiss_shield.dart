import 'dart:async';

import 'package:flutter/widgets.dart';

/// Ronda 8 (H-R8-7): mientras el reproductor a pantalla completa baja, la
/// pantalla de abajo no recibe toques.
///
/// Una ruta que se está cerrando ignora los toques (`ModalRoute` la envuelve en
/// un `IgnorePointer` durante la animación de salida), así que esos toques
/// caían en la pantalla de debajo: tras bajar el reproductor con el gesto, el
/// siguiente toque, que el usuario daba pensando que aún estaba ahí, ponía una
/// canción de la playlist.
final ValueNotifier<bool> playerDismissShield = ValueNotifier<bool>(false);

/// Margen tras terminar la animación: el dedo que bajó el reproductor suele
/// volver a tocar justo después.
const Duration _shieldTail = Duration(milliseconds: 150);

/// Sigue la animación de la ruta del reproductor y levanta el escudo mientras
/// se cierra.
class PlayerDismissShieldWatcher extends StatefulWidget {
  const PlayerDismissShieldWatcher({super.key, required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<PlayerDismissShieldWatcher> createState() => _PlayerDismissShieldWatcherState();
}

class _PlayerDismissShieldWatcherState extends State<PlayerDismissShieldWatcher> {
  Timer? _release;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(covariant PlayerDismissShieldWatcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
    }
  }

  void _onStatus(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.reverse:
        _release?.cancel();
        playerDismissShield.value = true;
      case AnimationStatus.dismissed:
        _scheduleRelease();
      case AnimationStatus.forward:
      case AnimationStatus.completed:
        _release?.cancel();
        playerDismissShield.value = false;
    }
  }

  void _scheduleRelease() {
    _release?.cancel();
    _release = Timer(_shieldTail, () => playerDismissShield.value = false);
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    // La ruta se va: el escudo nunca debe quedarse puesto.
    if (playerDismissShield.value) _scheduleRelease();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Bloquea los toques de [child] mientras [playerDismissShield] esté activo.
/// Siempre devuelve el mismo `AbsorbPointer` (Pitfall #33): solo cambia el
/// valor, nunca la estructura del árbol.
class PlayerDismissShield extends StatelessWidget {
  const PlayerDismissShield({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: playerDismissShield,
        builder: (context, shielded, child) => AbsorbPointer(absorbing: shielded, child: child),
        child: child,
      );
}
