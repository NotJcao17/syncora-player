import '../../player/player_models.dart';

/// Tipo de mix generado por Syncora para la pantalla de Inicio.
enum MixKind {
  /// Lo que el usuario más repitió en los últimos 30 días. Cadencia semanal.
  onRepeat,

  /// Radio de Deezer sembrada en uno de sus artistas más escuchados.
  artist,

  /// Chart del género que más escucha. Cadencia diaria.
  genre,

  /// Radio de un artista *relacionado* con los suyos, quitando lo que ya
  /// escuchó: sirve para descubrir, no para repetir.
  discovery,
}

/// Un mix es una **tirada congelada**, no una playlist.
///
/// Reglas de vida (acordadas con el usuario antes de implementar):
///
/// 1. **No se persiste nunca en la base de datos por su cuenta.** Vive en
///    memoria mientras la app está abierta, así que entrar y salir de él
///    devuelve exactamente la misma lista. Al reabrir la app se genera de
///    nuevo y puede ser distinto — eso es deseado.
/// 2. **Solo se congela en disco si el usuario lo guarda**, y entonces deja
///    de ser un mix: se convierte en una playlist normal suya, con fecha en
///    el nombre. Sin esa regla, Inicio iría creando decenas de playlists
///    fantasma sin que nadie las pidiera.
/// 3. [key] incluye la clave de periodo ([MixKind] + semilla temporal), que
///    es lo que decide cuándo *tocaría* regenerarlo.
class SyncoraMix {
  final String key;
  final MixKind kind;
  final String title;
  final String subtitle;
  final String coverUrl;
  final List<SyncoraTrack> tracks;

  const SyncoraMix({
    required this.key,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.tracks,
  });

  bool get isEmpty => tracks.isEmpty;

  /// ¿Lleva portada generada (color + ícono) en vez de una carátula real?
  ///
  /// On Repeat no es "el disco de la primera canción": es una lista tuya,
  /// como "Tus me gusta", y usar la carátula de su primera pista hacía creer
  /// justamente eso. Los mixes de artista y de género sí tienen una imagen que
  /// los representa de verdad (la foto del artista, la portada del género).
  bool get usesGeneratedCover => kind == MixKind.onRepeat;

  /// Nombre con el que se guarda en la biblioteca si el usuario lo guarda.
  /// Lleva fecha porque a partir de ese momento es una foto fija: sin fecha,
  /// dos guardados del mismo mix en semanas distintas serían indistinguibles.
  String savedTitle(DateTime now) {
    const meses = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
    ];
    return '$title · ${now.day} ${meses[now.month - 1]}';
  }
}
