import 'dart:async';

import 'audio_engine_state.dart';

/// Espera a que [stateStream] reporte que el motor efectivamente arrancó a
/// procesar la fuente (`playing`, o al menos `buffering`/`ready`) antes de
/// [timeout]. Devuelve `false` si el plazo se cumple sin que eso pase.
///
/// Diagnóstico del bug "se queda cargando en el primer intento" (ej.
/// "Mondlicht"): la extracción resuelve una URL válida, pero
/// `_engine.setUrl()`/`play()` a veces no logra arrancar el stream real en
/// el primer intento (falla muda del motor nativo al abrir la conexión) y el
/// `await` de `playCurrent()` queda colgado indefinidamente -- sin timeout
/// ni reintento, la UI se queda con el spinner de carga para siempre. Esta
/// función es una pieza aislada y testeable (no depende de `this` ni de un
/// motor real) que `SyncoraPlayerController` usa para decidir cuándo vale la
/// pena reintentar `setUrl()` una vez antes de rendirse.
Future<bool> awaitPlaybackStarted(
  Stream<AudioEngineState> stateStream,
  Duration timeout,
) async {
  final completer = Completer<bool>();
  late final StreamSubscription<AudioEngineState> sub;

  final timer = Timer(timeout, () {
    if (!completer.isCompleted) completer.complete(false);
  });

  sub = stateStream.listen((s) {
    if (completer.isCompleted) return;
    final started = s.playing ||
        s.processingState == AudioProcessingState.buffering ||
        s.processingState == AudioProcessingState.ready;
    if (started) completer.complete(true);
  });

  final result = await completer.future;
  timer.cancel();
  await sub.cancel();
  return result;
}
