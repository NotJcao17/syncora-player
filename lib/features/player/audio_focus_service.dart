import 'dart:async';

import 'package:audio_session/audio_session.dart';

/// Manejo de foco de audio e interrupciones del sistema (ronda 3, hallazgo
/// H-R3-1).
///
/// Hasta esta ronda, `audio_session` existía en el proyecto **solo como
/// dependencia transitiva** de `just_audio`/`audio_service` y no se usaba en
/// ninguna parte: no había `configure(...)`, ni suscripción a
/// `interruptionEventStream`, ni a `becomingNoisyEventStream`. `just_audio`
/// no gestiona las interrupciones por su cuenta — es responsabilidad de la
/// app. Eso explicaba varios fallos reportados en Android que parecían
/// distintos entre sí:
///
/// - una alarma detenía la música y, al apagarla, la reproducción quedaba
///   trabada;
/// - una historia de Instagram (o cualquier audio ajeno) dejaba la app
///   pausada **y con el reproductor de la pantalla de bloqueo cerrado**,
///   obligando a volver a abrir la app para reanudar;
/// - "de repente se detuvo el audio".
///
/// ## Contrato
///
/// Este servicio **nunca toca el motor de audio directamente**: solo llama a
/// los callbacks de pausa/reanudación que le inyecta
/// `player_providers.dart`, que van al camino de reproducción del
/// controlador. Es la regla de §2.1 de `correcciones_qa_post_fase_7.md`
/// ("nada escribe en el motor fuera del camino de reproducción del
/// controlador").
///
/// ## Por qué no se hace nada ante `duck`
///
/// En Android, si no se pide `androidWillPauseWhenDucked`, **el sistema
/// atenúa el volumen por su cuenta** ante un `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK`
/// (una notificación corta, el navegador dando indicaciones). Bajar el
/// volumen a mano además sería peligroso aquí: el volumen del motor se
/// persiste en la sesión, así que una app cerrada en mitad de un duck
/// reabriría con el volumen atenuado y sin forma obvia de saber por qué.
///
/// ## Por qué `unknown` no reanuda
///
/// `AudioInterruptionType.unknown` corresponde a una pérdida de foco
/// **permanente** (otra app se quedó con la reproducción). Reanudar ahí
/// sería pelearle el audio al usuario. Solo `pause` (pérdida transitoria)
/// reanuda.
class AudioFocusService {
  AudioFocusService({
    required Future<void> Function() onPause,
    required Future<void> Function() onResume,
    required bool Function() isPlaying,
    void Function(String message)? log,
  })  : _onPause = onPause, // ignore: prefer_initializing_formals
        _onResume = onResume, // ignore: prefer_initializing_formals
        _isPlaying = isPlaying, // ignore: prefer_initializing_formals
        _log = log; // ignore: prefer_initializing_formals

  final Future<void> Function() _onPause;
  final Future<void> Function() _onResume;
  final bool Function() _isPlaying;
  final void Function(String message)? _log;

  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _noisySub;
  bool _disposed = false;

  /// ¿La pausa vigente la causó una interrupción del sistema (y no el
  /// usuario)?
  ///
  /// Es lo único que distingue "reanuda al acabar la alarma" de "el usuario
  /// pausó mientras sonaba la alarma, no le devuelvas la música en la cara".
  /// Se limpia siempre al final de la interrupción, así que no puede
  /// quedarse pegada entre interrupciones distintas.
  bool _pausedByInterruption = false;

  /// Visible para tests.
  bool get pausedByInterruption => _pausedByInterruption;

  /// Configura la sesión de audio como reproductor de música y engancha los
  /// dos streams del sistema. Idempotente por construcción: el proveedor la
  /// crea una sola vez por instancia de controlador.
  Future<void> attach() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    if (_disposed) return;
    _interruptionSub = session.interruptionEventStream.listen(handleInterruption);
    _noisySub = session.becomingNoisyEventStream.listen((_) => handleBecomingNoisy());
  }

  /// Punto de entrada de la máquina de estados, separado de [attach] para
  /// poder ejercitarlo en tests sin el plugin nativo detrás.
  void handleInterruption(AudioInterruptionEvent event) {
    if (_disposed) return;
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          // Android atenúa solo. No hacer nada es lo correcto.
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          // Solo se marca como "pausa por interrupción" si de verdad estaba
          // sonando: si el usuario ya lo tenía pausado, al acabar la
          // interrupción no debe arrancar nada.
          if (_isPlaying()) {
            _pausedByInterruption = true;
            _log?.call('[Focus] Interrupción (${event.type.name}): pausando.');
            unawaited(_onPause());
          }
          break;
      }
      return;
    }

    switch (event.type) {
      case AudioInterruptionType.duck:
        break;
      case AudioInterruptionType.pause:
        if (_pausedByInterruption) {
          _log?.call('[Focus] Fin de la interrupción: reanudando.');
          unawaited(_onResume());
        }
        break;
      case AudioInterruptionType.unknown:
        // Pérdida permanente de foco: no se recupera la reproducción.
        break;
    }
    _pausedByInterruption = false;
  }

  /// Auriculares/Bluetooth desconectados. Comportamiento estándar de
  /// cualquier reproductor: pausar, nunca seguir sonando por el altavoz.
  /// No se marca [_pausedByInterruption]: volver a conectar los auriculares
  /// no debe reanudar solo.
  void handleBecomingNoisy() {
    if (_disposed) return;
    if (!_isPlaying()) return;
    _log?.call('[Focus] Salida de audio desconectada: pausando.');
    unawaited(_onPause());
  }

  void dispose() {
    _disposed = true;
    _interruptionSub?.cancel();
    _noisySub?.cancel();
    _interruptionSub = null;
    _noisySub = null;
  }
}
