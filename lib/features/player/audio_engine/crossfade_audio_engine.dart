import 'dart:async';

import 'audio_engine_state.dart';

/// Wrapper genérico y agnóstico de plataforma que agrega **crossfade real**
/// (Fase 7.D, ver `docs/plan_fase_7.md` 7.D.1-7.D.3 y Documento Maestro §2.4)
/// a cualquier [AudioEngine] concreto, sin tocar la implementación nativa de
/// [MediaKitEngine]/[JustAudioEngine] por dentro.
///
/// Envuelve DOS instancias completas de [AudioEngine] — no necesita saber
/// cuáles son ([createEngine] las produce, sea cual sea la fábrica real que
/// decide la plataforma). `_active` es el motor "de verdad" que suena ahora;
/// `_standby` es el motor de la próxima transición, creado perezosamente la
/// primera vez que se necesita un crossfade real: no se paga el costo de una
/// segunda instancia nativa de audio para usuarios que nunca lo activan.
///
/// Todos los métodos "normales" del contrato ([setUrl], [setLocalSource],
/// [play], [pause], [stop], [seek]) delegan directo a `_active` — el
/// comportamiento de cualquier transición SIN crossfade es exactamente el
/// mismo de siempre, sin ninguna diferencia observable para el controlador.
/// [setSpeed]/[setVolume]/[setSkipSilenceEnabled] además recuerdan el último
/// valor pedido ("canónico") para poder aplicárselo a `_standby` cuando
/// despierte de su letargo (ver docstring de [crossfadeToLocalSource]).
///
/// [stateStream]/[completionStream]/[logStream] son streams propios del
/// wrapper que reenvían lo que emite `_active` en cada momento. `_active`
/// cambia — y el wrapper se resuscribe a él — en cuanto arranca un
/// crossfade, no cuando termina (ver docstring de [crossfadeToLocalSource]).
///
/// ## Rediseño post-revisión de código (Fase 7.D)
/// La primera versión de este wrapper tenía 6 problemas de diseño/
/// implementación encontrados en revisión independiente, todos corregidos
/// acá: (1) el `Future` de un fade cancelado/reemplazado podía quedar
/// colgado para siempre, trabando el reproductor; (2) el controlador
/// quedaba bloqueado por toda la duración del fade (2-6s) para poder saltar
/// de pista de nuevo; (3) `_standby` nunca recibía velocidad/Skip Silence/
/// volumen mientras dormía, y el swap forzaba el volumen a 1.0 pisando el
/// del usuario; (4) los streams del wrapper seguían apuntando al motor
/// saliente durante todo el fade; (5) un `Timer.periodic` con callback
/// `async` podía solapar pasos del ramp de volumen. Ver docstring de
/// [crossfadeToLocalSource] para el diseño final de cada punto.
class CrossfadeAudioEngine implements AudioEngine {
  CrossfadeAudioEngine({
    required AudioEngine Function() createEngine,
    required Duration Function() fadeDurationGetter,
  })  : _createEngine = createEngine,
        _fadeDurationGetter = fadeDurationGetter,
        _active = createEngine() {
    _resubscribeTo(_active);
  }

  final AudioEngine Function() _createEngine;

  /// Lee el setting de duración de crossfade en vivo (sin reconstruir el
  /// engine si el usuario lo cambia en Configuración mientras la app sigue
  /// abierta). Se usa como fallback cuando [crossfadeToLocalSource] recibe
  /// `Duration.zero` (sentinel de "usa el valor configurado") en vez de una
  /// duración explícita.
  final Duration Function() _fadeDurationGetter;

  AudioEngine _active;
  AudioEngine? _standby;

  final StreamController<AudioEngineState> _stateController =
      StreamController<AudioEngineState>.broadcast();
  final StreamController<void> _completionController =
      StreamController<void>.broadcast();
  final StreamController<String> _logStreamController =
      StreamController<String>.broadcast();

  StreamSubscription<AudioEngineState>? _activeStateSub;
  StreamSubscription<void>? _activeCompletionSub;
  StreamSubscription<String>? _activeLogSub;

  // --- Valores "canónicos" (los que el usuario realmente pidió) ----------
  // `_standby` puede pasar minutos dormido sin recibir ningún setSpeed/
  // setSkipSilenceEnabled/setVolume mientras estuvo inactivo — sin este
  // registro, al despertar (justo antes de sonar) se quedaría con los
  // valores por defecto del motor nativo (velocidad 1.0x, Skip Silence
  // apagado) y el swap final forzaría el volumen a 1.0 fijo, pisando el que
  // el usuario tuviera puesto (salto de volumen audible).
  double _canonicalVolume = 1.0;
  double _canonicalSpeed = 1.0;
  bool _canonicalSkipSilence = false;

  /// Generación del fade en segundo plano actualmente "dueño" de
  /// `_pendingFadeCompleter` — permite que una llamada nueva a
  /// [crossfadeToLocalSource] invalide instantáneamente cualquier fade
  /// anterior en vuelo (bump de generación) sin necesitar un `Timer` que
  /// cancelar: el bucle del fade viejo se revisa a sí mismo en cada paso y
  /// se detiene solo en cuanto detecta que ya no es la generación vigente.
  /// También usado por [dispose] para invalidar cualquier fade en curso.
  int _fadeGeneration = 0;

  /// `Completer` del fade en segundo plano actualmente en vuelo (si hay
  /// uno). Se completa SIEMPRE — en su bloque `finally`, cubriendo todo
  /// camino de salida (fin normal, invalidado por una llamada nueva,
  /// invalidado por `dispose()`) — nunca se deja colgado. Expuesto vía
  /// [debugAwaitFadeSettled] únicamente para que los tests puedan esperar a
  /// que el fade en background termine de forma determinista, sin depender
  /// de temporizadores reales.
  Completer<void>? _pendingFadeCompleter;

  void _resubscribeTo(AudioEngine engine) {
    _activeStateSub?.cancel();
    _activeCompletionSub?.cancel();
    _activeLogSub?.cancel();
    _activeStateSub = engine.stateStream.listen((s) {
      if (!_stateController.isClosed) _stateController.add(s);
    });
    _activeCompletionSub = engine.completionStream.listen((_) {
      if (!_completionController.isClosed) _completionController.add(null);
    });
    _activeLogSub = engine.logStream.listen((l) {
      if (!_logStreamController.isClosed) _logStreamController.add(l);
    });
  }

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Stream<String> get logStream => _logStreamController.stream;

  @override
  Duration get position => _active.position;

  @override
  Duration get duration => _active.duration;

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers}) =>
      _active.setUrl(url, headers: headers);

  @override
  Future<void> setLocalSource(String path) => _active.setLocalSource(path);

  @override
  Future<void> play() => _active.play();

  @override
  Future<void> pause() => _active.pause();

  @override
  Future<void> stop() => _active.stop();

  @override
  Future<void> seek(Duration position) => _active.seek(position);

  @override
  Future<void> setSpeed(double speed) {
    _canonicalSpeed = speed;
    return _active.setSpeed(speed);
  }

  @override
  Future<void> setVolume(double volume) {
    _canonicalVolume = volume.clamp(0.0, 1.0);
    return _active.setVolume(volume);
  }

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) {
    _canonicalSkipSilence = enabled;
    return _active.setSkipSilenceEnabled(enabled);
  }

  /// Crossfade real (Fase 7.D.1-7.D.3, rediseño post-revisión).
  ///
  /// Secuencia:
  /// 1. Si ya había un fade en background en vuelo (dos llamadas
  ///    solapadas), se invalida de inmediato (bump de [_fadeGeneration]) y
  ///    se completa su `Completer` pendiente sin esperar a que su bucle lo
  ///    note — nunca se deja un `Future` colgado.
  /// 2. `_standby` se crea si hace falta, y recibe los valores canónicos
  ///    actuales (velocidad, Skip Silence, volumen en 0 para arrancar en
  ///    silencio) ANTES de cargar y reproducir la pista nueva.
  /// 3. **Swap inmediato**: `_active`/`_standby` se intercambian y el
  ///    wrapper se resuscribe al motor entrante ANTES de que arranque el
  ///    ramp de volumen — así `position`/`duration`/`stateStream` reflejan
  ///    la pista ENTRANTE desde el principio del fade (no recién al
  ///    final), y para cuando el motor saliente llegue a su propio EOF
  ///    natural (con el disparo preventivo del controlador, esto ocurre
  ///    casi exactamente al final del fade, por diseño) el wrapper ya no
  ///    está escuchando sus streams — ese evento no se propaga.
  /// 4. Este método **resuelve aquí** (rápido: solo esperó los pasos 2-3) —
  ///    el ramp de volumen de 50ms por paso sigue corriendo en segundo
  ///    plano sin bloquear al llamador. El guard de transición del
  ///    controlador (`_isTransitioning`) no debe quedar inutilizable por
  ///    toda la duración del fade.
  /// 5. En segundo plano: baja el volumen del saliente y sube el del
  ///    entrante en paralelo hasta el volumen canónico del usuario (nunca
  ///    fijo a 1.0), y al terminar detiene el motor saliente.
  @override
  Future<void> crossfadeToLocalSource(String path, Duration duration) async {
    // Punto 1: invalidar cualquier fade en background en vuelo. El bucle
    // viejo se detendrá solo en su próximo paso (ver `_runBackgroundFade`),
    // pero su `Completer` se completa AQUÍ, de inmediato — no hay que
    // esperar a que el bucle note el cambio para liberar a quien lo estaba
    // esperando (ver `debugAwaitFadeSettled`).
    _fadeGeneration++;
    final stalePending = _pendingFadeCompleter;
    if (stalePending != null && !stalePending.isCompleted) {
      stalePending.complete();
    }
    _pendingFadeCompleter = null;

    _standby ??= _createEngine();
    final incoming = _standby!;
    final outgoing = _active;

    // Punto 2: valores canónicos al motor entrante ANTES de que suene.
    await incoming.setVolume(0.0);
    await incoming.setSpeed(_canonicalSpeed);
    await incoming.setSkipSilenceEnabled(_canonicalSkipSilence);
    await incoming.setLocalSource(path);
    await incoming.play();

    // Punto 3: swap inmediato — el wrapper ya "es" el motor entrante para
    // cualquier llamador externo a partir de aquí.
    _active = incoming;
    _standby = outgoing;
    _resubscribeTo(_active);

    final effectiveDuration =
        duration > Duration.zero ? duration : _fadeDurationGetter();

    if (effectiveDuration <= Duration.zero) {
      // Guard defensivo: el controlador ya solo llama a este método con
      // duration > 0, pero si algo lo invocara sin duración configurada,
      // se resuelve el swap sin animación en vez de dividir por cero en
      // los pasos del ramp.
      await outgoing.setVolume(0.0);
      await incoming.setVolume(_canonicalVolume);
      try {
        await outgoing.stop();
      } catch (_) {}
      return;
    }

    // Punto 4/5: el ramp sigue en segundo plano — `unawaited` a propósito.
    final myFadeGen = ++_fadeGeneration;
    final completer = Completer<void>();
    _pendingFadeCompleter = completer;
    unawaited(_runBackgroundFade(
      outgoing: outgoing,
      incoming: incoming,
      duration: effectiveDuration,
      myFadeGen: myFadeGen,
      completer: completer,
    ));
  }

  /// Ramp de volumen en segundo plano (Fase 7.D, rediseño). Usa un bucle
  /// secuencial con `await Future.delayed(...)` entre pasos — a diferencia
  /// de `Timer.periodic` con un callback `async`, esto GARANTIZA que un
  /// paso nunca arranca antes de que el anterior termine de escribir
  /// ambos volúmenes, sin importar cuánto tarde el motor nativo en
  /// responder.
  ///
  /// [myFadeGen] es la generación capturada al arrancar este fade —
  /// [isStale] compara contra [_fadeGeneration] en cada punto de posible
  /// interrupción (una llamada nueva a [crossfadeToLocalSource], o
  /// [dispose]) y el bucle se detiene solo en cuanto deja de ser vigente,
  /// sin tocar motores que ya no le "pertenecen". El `Completer` se
  /// completa SIEMPRE en el `finally`, cubriendo todo camino de salida.
  Future<void> _runBackgroundFade({
    required AudioEngine outgoing,
    required AudioEngine incoming,
    required Duration duration,
    required int myFadeGen,
    required Completer<void> completer,
  }) async {
    bool isStale() => myFadeGen != _fadeGeneration;
    try {
      const stepInterval = Duration(milliseconds: 50);
      final totalSteps =
          (duration.inMilliseconds / stepInterval.inMilliseconds).ceil().clamp(1, 1000000);
      var currentStep = 0;

      while (currentStep < totalSteps) {
        await Future.delayed(stepInterval);
        if (isStale()) return;
        currentStep++;
        final t = (currentStep / totalSteps).clamp(0.0, 1.0);
        try {
          await outgoing.setVolume(((1.0 - t) * _canonicalVolume).clamp(0.0, _canonicalVolume));
          if (isStale()) return;
          await incoming.setVolume((t * _canonicalVolume).clamp(0.0, _canonicalVolume));
        } catch (_) {
          // Un motor puede fallar a mitad de fade — no debe tumbar el
          // bucle, solo se ignora ese paso y se sigue hacia el final.
        }
        if (isStale()) return;
      }

      await incoming.setVolume(_canonicalVolume);
      try {
        await outgoing.stop();
      } catch (_) {}
    } finally {
      if (!isStale() && identical(_pendingFadeCompleter, completer)) {
        _pendingFadeCompleter = null;
      }
      if (!completer.isCompleted) completer.complete();
    }
  }

  /// Solo para tests: espera a que el fade en background actualmente en
  /// vuelo (si hay uno) termine de resolverse — evita que los tests
  /// dependan de temporizadores reales o de sondear el estado a ciegas.
  /// No forma parte del contrato [AudioEngine].
  Future<void> debugAwaitFadeSettled() =>
      _pendingFadeCompleter?.future ?? Future.value();

  @override
  void dispose() {
    // Invalida cualquier fade en background en curso y completa su
    // `Completer` de inmediato — igual que en el punto 1 de
    // [crossfadeToLocalSource], nunca se deja colgado.
    _fadeGeneration++;
    final pending = _pendingFadeCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    _pendingFadeCompleter = null;

    _activeStateSub?.cancel();
    _activeCompletionSub?.cancel();
    _activeLogSub?.cancel();
    _stateController.close();
    _completionController.close();
    _logStreamController.close();
    _active.dispose();
    _standby?.dispose();
  }
}
