import 'dart:async';
import 'dart:math' as math;

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
    required this._fadeDurationGetter,
  })  : _createEngine = createEngine,
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

  /// Piso del ramp de volumen al descontarle el tiempo de preparación del
  /// motor entrante (ver [crossfadeToLocalSource]).
  static const Duration _minFadeDuration = Duration(milliseconds: 250);

  /// Hallazgo real de revisión independiente (F-1): `_pendingFadeCompleter`
  /// recién se asigna al FINAL de [crossfadeToLocalSource], después de ~6
  /// `await` sobre el motor entrante (crear el `Player`, setVolume/setSpeed/
  /// setSkipSilenceEnabled, setLocalSource, play). Si una transición NORMAL
  /// (`setUrl`/`setLocalSource`/`pause`/`stop`/`seek`, vía
  /// [_settleFadeBeforeNormalTransition]) cae en esa ventana, no encuentra
  /// ningún fade "pendiente" que cerrar -- pero `_active` TODAVÍA es el
  /// motor saliente (el swap ocurre recién después de esos `await`s), así
  /// que la transición normal termina cargando la pista nueva en el motor
  /// que está a punto de pasar a `_standby`, y el swap del crossfade lo pisa
  /// igual acto seguido: suena la pista equivocada, con un fade fantasma.
  /// Este `Completer` cubre exactamente esa ventana de "setup en curso" --
  /// [_settleFadeBeforeNormalTransition] espera a que se resuelva ANTES de
  /// decidir qué hacer, así nunca hay ambigüedad sobre cuál motor es
  /// `_active` en el momento de actuar.
  Completer<void>? _setupCompleter;

  /// El volumen que el wrapper reporta hacia afuera es SIEMPRE el canónico
  /// (el que el usuario pidió), nunca el volumen físico instantáneo del
  /// motor activo.
  ///
  /// Bug real reportado en pruebas manuales: "la barra de volumen empieza
  /// desde abajo". El ramp de crossfade escribe un volumen nuevo en el motor
  /// entrante cada 50ms, arrancando en 0 — y como el swap de `_active` ocurre
  /// al principio del fade, esas escrituras se reenviaban tal cual a la UI,
  /// que lee `state.engine.volume` para el slider. El resultado era el slider
  /// deslizándose solo de 0 al valor del usuario en cada transición. El
  /// volumen del ramp es un detalle interno de implementación del fundido: el
  /// nivel que el usuario eligió no cambió en ningún momento.
  AudioEngineState _withCanonicalVolume(AudioEngineState s) =>
      s.volume == _canonicalVolume ? s : s.copyWith(volume: _canonicalVolume);

  void _resubscribeTo(AudioEngine engine) {
    _activeStateSub?.cancel();
    _activeCompletionSub?.cancel();
    _activeLogSub?.cancel();
    _activeStateSub = engine.stateStream.listen((s) {
      if (!_stateController.isClosed) _stateController.add(_withCanonicalVolume(s));
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
  Future<void> setUrl(String url, {Map<String, String>? headers}) async {
    await _settleFadeBeforeNormalTransition();
    return _active.setUrl(url, headers: headers);
  }

  @override
  Future<void> setLocalSource(String path) async {
    await _settleFadeBeforeNormalTransition();
    _prewarmStandbyIfCrossfadeEnabled();
    return _active.setLocalSource(path);
  }

  /// Cierra a mano un fade que siga en vuelo cuando llega una transición
  /// NORMAL (el usuario saltó de pista a mitad del fundido, o la pista
  /// siguiente no era local y se resolvió por streaming).
  ///
  /// Sin esto quedaban dos rastros audibles del fade abortado: (1) el motor
  /// saliente seguía reproduciendo su pista, porque solo `_runBackgroundFade`
  /// lo detiene al terminar y el bucle se corta antes de llegar ahí — dos
  /// pistas sonando a la vez de forma permanente; (2) el motor entrante (ya
  /// `_active`) se quedaba con el volumen parcial del paso del ramp donde se
  /// cortó, así que la pista nueva arrancaba a un volumen arbitrario más bajo
  /// que el que el usuario tenía puesto.
  Future<void> _settleFadeBeforeNormalTransition() async {
    // F-1: si un crossfade está a mitad de preparar su motor entrante
    // (`_active` todavía no cambió), esperar a que termine de reclamarlo
    // antes de decidir nada -- si no, esta transición normal actuaría sobre
    // el motor equivocado.
    final setup = _setupCompleter;
    if (setup != null && !setup.isCompleted) {
      await setup.future;
    }

    final pending = _pendingFadeCompleter;
    if (pending == null) return;
    _fadeGeneration++;
    if (!pending.isCompleted) pending.complete();
    _pendingFadeCompleter = null;
    try {
      await _standby?.stop();
    } catch (_) {}
    try {
      await _active.setVolume(_canonicalVolume);
    } catch (_) {}
  }

  /// Crea `_standby` por adelantado (sin cargar nada en él) la primera vez
  /// que suena un archivo local con el crossfade activado.
  ///
  /// Sigue siendo perezoso para quien nunca activa la función — pero, si está
  /// activada, construir la segunda instancia nativa DENTRO de
  /// [crossfadeToLocalSource] metía toda la latencia de arranque del motor
  /// (en Windows, un `Player` de libmpv completo) entre el instante en que el
  /// controlador decide cruzar y el instante en que el ramp de volumen
  /// realmente empieza. Como el fade preventivo dura exactamente lo que le
  /// queda a la pista saliente, esa demora se comía el final del fundido: la
  /// pista vieja llegaba a su fin real con la nueva todavía a medio subir —
  /// justo el "suena un pedazo de la anterior y después la nueva" del reporte
  /// de pruebas manuales.
  void _prewarmStandbyIfCrossfadeEnabled() {
    if (_standby != null) return;
    if (_fadeDurationGetter() <= Duration.zero) return;
    try {
      _standby = _createEngine();
    } catch (_) {}
  }

  @override
  Future<void> play() => _active.play();

  // `pause`/`stop`/`seek` también tienen que cerrar el fade en vuelo: sin
  // esto, el motor SALIENTE no lo detiene nadie hasta que el ramp llegue
  // solo a su último paso, así que pausar o parar a mitad de un cruce dejaba
  // la pista anterior sonando igual (el usuario para la música y sigue
  // escuchando audio). `_settleFadeBeforeNormalTransition` no cuesta nada
  // cuando no hay ningún fade pendiente.
  @override
  Future<void> pause() async {
    await _settleFadeBeforeNormalTransition();
    return _active.pause();
  }

  @override
  Future<void> stop() async {
    await _settleFadeBeforeNormalTransition();
    return _active.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _settleFadeBeforeNormalTransition();
    return _active.seek(position);
  }

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

  /// Micro fade-out interno (~120-150ms) en el motor activo para transiciones limpias y anti-pop.
  /// No modifica [_canonicalVolume], por lo que el estado observable hacia la UI permanece intacto
  /// (la barra de volumen no se mueve visualmente ni parpadea).
  @override
  Future<void> microFadeOut() async {
    final curVol = _canonicalVolume;
    if (curVol <= 0.0) return;
    try {
      final step = curVol / 3.0;
      await _active.setVolume((curVol - step).clamp(0.0, 1.0));
      await Future.delayed(const Duration(milliseconds: 40));
      await _active.setVolume((curVol - 2 * step).clamp(0.0, 1.0));
      await Future.delayed(const Duration(milliseconds: 40));
      await _active.setVolume(0.0);
      await Future.delayed(const Duration(milliseconds: 40));
    } catch (_) {}
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

    // F-1: marca el inicio de la ventana en la que `_active` todavía es el
    // motor SALIENTE pero ya está "comprometido" con este crossfade -- ver
    // docstring de [_setupCompleter]. Se resuelve recién después del swap,
    // nunca antes, y siempre (éxito o excepción) vía el `finally` de abajo.
    final setupCompleter = Completer<void>();
    _setupCompleter = setupCompleter;

    try {
      final setupClock = Stopwatch()..start();

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
      // El swap ya pasó -- `_active` es correcto a partir de acá, así que
      // cualquier `_settleFadeBeforeNormalTransition` esperando puede seguir
      // ya mismo, sin necesidad de esperar también a que termine el resto
      // (cálculo de duración + arranque del ramp, que no cambian de nuevo
      // cuál motor es cuál).
      if (!setupCompleter.isCompleted) setupCompleter.complete();
      await _crossfadeBody(outgoing, incoming, duration, setupClock);
    } finally {
      if (!setupCompleter.isCompleted) setupCompleter.complete();
    }
  }

  /// Resto de [crossfadeToLocalSource] tras el swap (cálculo de duración
  /// efectiva + arranque del ramp en background).
  Future<void> _crossfadeBody(
    AudioEngine outgoing,
    AudioEngine incoming,
    Duration duration,
    Stopwatch setupClock,
  ) async {
    final requestedDuration =
        duration > Duration.zero ? duration : _fadeDurationGetter();

    // La duración pedida se cuenta desde el instante en que el controlador
    // DECIDIÓ cruzar, no desde acá: cargar y arrancar el motor entrante ya
    // consumió parte de esa ventana. En el crossfade preventivo la duración
    // pedida es exactamente lo que le queda de audio a la pista saliente, así
    // que si el ramp durara la duración completa terminaría DESPUÉS del fin
    // real de la pista vieja — el saliente se queda mudo por su cuenta a
    // mitad del fundido y lo que se oye es un corte, no un cruce (síntoma
    // reportado en pruebas manuales). Descontar el tiempo de preparación
    // mantiene el final del ramp alineado con el final real de la pista
    // saliente. Nunca se acorta por debajo de [_minFadeDuration]: un ramp de
    // pocos milisegundos suena igual que un corte seco.
    setupClock.stop();
    final compensated = requestedDuration - setupClock.elapsed;
    final floor =
        requestedDuration < _minFadeDuration ? requestedDuration : _minFadeDuration;
    final effectiveDuration = requestedDuration <= Duration.zero
        ? Duration.zero
        : (compensated < floor ? floor : compensated);

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
        // Curva de potencia constante (equal-power), no lineal: con dos
        // rampas lineales opuestas, en el punto medio cada pista está a la
        // mitad de amplitud y la suma percibida cae ~3 dB — un bache de
        // volumen audible justo en el medio del cruce, que refuerza la
        // sensación de "corte" en vez de fundido. `cos`/`sin` mantienen
        // constante la potencia total durante todo el cruce.
        final outVol = t >= 1.0 ? 0.0 : math.cos(t * math.pi / 2) * _canonicalVolume;
        final inVol = t >= 1.0 ? _canonicalVolume : math.sin(t * math.pi / 2) * _canonicalVolume;
        try {
          await outgoing.setVolume(outVol.clamp(0.0, _canonicalVolume));
          if (isStale()) return;
          await incoming.setVolume(inVol.clamp(0.0, _canonicalVolume));
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
