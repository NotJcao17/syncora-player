import 'dart:io';

import 'package:flutter/foundation.dart';

import 'audio_engine_state.dart';
import 'just_audio_engine.dart';
import 'media_kit_engine.dart';

/// Construye el [AudioEngine] apropiado para la plataforma actual.
///
/// - Android → [JustAudioEngine] (ExoPlayer).
/// - Windows → [MediaKitEngine] (libmpv).
/// - Web     → [JustAudioEngine] (solo para pruebas de UI; Pitfall #6).
///
/// La selección se centraliza aquí para que el resto del reproductor dependa
/// únicamente del contracto [AudioEngine].
AudioEngine createAudioEngine() {
  if (kIsWeb) {
    // Web: usar just_audio como bypass para validar UI sin binarios nativos.
    return JustAudioEngine();
  }
  if (Platform.isWindows) {
    return MediaKitEngine();
  }
  // Android (y fallback móvil).
  return JustAudioEngine();
}
