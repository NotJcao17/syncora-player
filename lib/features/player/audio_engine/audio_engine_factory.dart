import 'dart:io';

import 'package:flutter/foundation.dart';

import 'audio_engine_state.dart';
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
AudioEngine createAudioEngine() {
  if (kIsWeb) {
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
