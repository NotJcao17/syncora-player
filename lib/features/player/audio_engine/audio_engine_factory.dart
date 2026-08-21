import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'audio_engine_state.dart';
import 'crossfade_audio_engine.dart';
import 'just_audio_engine.dart';
import 'media_kit_engine.dart';

/// Construye el [AudioEngine] apropiado para la plataforma actual.
///
/// - Android → [JustAudioEngine] (ExoPlayer).
/// - Windows → [MediaKitEngine] (libmpv), con fallback seguro a [JustAudioEngine] si falla en entorno de pruebas.
/// - Web     → [JustAudioEngine] (solo para pruebas de UI; Pitfall #6).
///
/// La selección se centraliza aquí para que el resto del reproductor dependa
/// únicamente del contrato [AudioEngine].
bool get _isTestEnv {
  try {
    final name = WidgetsBinding.instance.runtimeType.toString();
    return name.contains('Test') || name.contains('Automated');
  } catch (_) {
    return true;
  }
}

AudioEngine _createRawEngine() {
  if (kIsWeb || _isTestEnv) {
    return JustAudioEngine();
  }
  if (Platform.isWindows) {
    try {
      return MediaKitEngine();
    } catch (_) {
      return JustAudioEngine();
    }
  }
  return JustAudioEngine();
}

/// Construye el motor de audio de la plataforma actual, envuelto SIEMPRE en
/// [CrossfadeAudioEngine] (Fase 7.D). El wrapper es barato cuando el usuario
/// nunca activa crossfade (`_standby` es perezoso, ver docstring de
/// [CrossfadeAudioEngine]), así que envolverlo incondicionalmente no cambia
/// el comportamiento observable de ninguna transición normal.
///
/// [fadeDurationGetter] conecta el setting de Configuración de duración de
/// crossfade (`crossfadeDurationProvider` en `player_providers.dart`) — el
/// default `Duration.zero` ("off") preserva el comportamiento de cualquier
/// call site/test que siga llamando a esta función sin argumentos.
AudioEngine createAudioEngine({
  Duration Function() fadeDurationGetter = _zeroDuration,
}) {
  return CrossfadeAudioEngine(
    createEngine: _createRawEngine,
    fadeDurationGetter: fadeDurationGetter,
  );
}

Duration _zeroDuration() => Duration.zero;
