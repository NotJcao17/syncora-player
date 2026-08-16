import 'dart:async';

/// Estado de procesamiento del motor de audio, agnóstico de plataforma.
///
/// Unifica los estados internos de `just_audio` (Android) y `media_kit`
/// (Windows) para que el [SyncoraPlayerController] y la UI no dependan
/// de ninguno de los dos paquetes concretos.
enum AudioProcessingState {
  idle,
  loading,
  buffering,
  ready,
  completed,
  error,
}

/// Modos de repetición (Pitfall #7 — el gapless entre canciones lo resuelve
/// ExoPlayer/libmpv nativamente; esto solo controla el comportamiento de cola).
enum RepeatMode { off, one, all }

/// Snapshot inmutable del estado de reproducción en un instante.
class AudioEngineState {
  final AudioProcessingState processingState;
  final bool playing;
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;
  final double speed;
  final double volume;

  const AudioEngineState({
    this.processingState = AudioProcessingState.idle,
    this.playing = false,
    this.position = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.duration = Duration.zero,
    this.speed = 1.0,
    this.volume = 1.0,
  });

  /// Conveniencia: ¿hay audio cargado y listo (o reproduciéndose/buffering)?
  bool get isActive =>
      processingState == AudioProcessingState.ready ||
      processingState == AudioProcessingState.buffering;

  static const AudioEngineState initial = AudioEngineState();

  AudioEngineState copyWith({
    AudioProcessingState? processingState,
    bool? playing,
    Duration? position,
    Duration? bufferedPosition,
    Duration? duration,
    double? speed,
    double? volume,
  }) {
    return AudioEngineState(
      processingState: processingState ?? this.processingState,
      playing: playing ?? this.playing,
      position: position ?? this.position,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      duration: duration ?? this.duration,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
    );
  }
}

/// Contractura común para los motores de audio de cada plataforma.
///
/// Las implementaciones ([JustAudioEngine] en Android y [MediaKitEngine] en
/// Windows) traducen este contrato a la API concreta de cada paquete. El
/// [SyncoraPlayerController] habla únicamente con esta interfaz, por lo que la
/// lógica de cola, reproductor y controles del SO queda 100% compartida.
abstract class AudioEngine {
  /// Stream único con snapshots del estado. Último valor retenido (broadcast).
  Stream<AudioEngineState> get stateStream;

  /// Stream discreto que se emite cuando una pista termina de reproducirse.
  Stream<void> get completionStream;

  /// Líneas de log/diagnóstico del motor nativo (errores HTTP, de demuxer,
  /// etc.) — se reenvían al panel de logs de la app para poder diagnosticar
  /// fallos de reproducción que no llegan como excepción Dart.
  Stream<String> get logStream;

  /// Carga una URL de streaming con sus headers HTTP obligatorios.
  ///
  /// Los headers DEBEN ser los mismos con los que se generó la firma de la
  /// URL (Pitfall #13), o YouTube devolverá 403 silenciosamente.
  Future<void> setUrl(String url, {Map<String, String>? headers});

  /// Carga un archivo de audio descargado localmente sin peticiones HTTP.
  Future<void> setLocalSource(String path);


  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);

  /// Recorte de silencios. En Android delega al flag de ExoPlayer (solo para
  /// spoken-word/podcasts, Pitfall #7); en Windows alterna el filtro
  /// `silencedetect` de libmpv y ejecuta un seek al primer sample de audio.
  Future<void> setSkipSilenceEnabled(bool enabled);

  /// Posición actual (snapshot). Para UI reactiva usar [stateStream].
  Duration get position;
  Duration get duration;

  void dispose();
}
