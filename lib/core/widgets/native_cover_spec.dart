import 'package:flutter/painting.dart';

import '../../data/local_db/syncora_database.dart';
import '../theme/app_theme.dart';
import '../utils/local_image_path.dart';
import 'playlist_cover_widget.dart';

/// Portada de una playlist tal como la dibuja la app, en un formato que
/// entiende el lado nativo (Android Auto y widgets, ronda 13).
///
/// En la app, "Tus me gusta" y "On Repeat" no tienen portada guardada (se
/// pintan con su degradado y su ícono) y muchas playlists tienen de portada un
/// degradado o un color (`gradient:N`, `color:#hex`), que no son imágenes. Sin
/// esto, Android Auto mostraba un triángulo de error y los widgets un cuadro
/// vacío o la carátula de una canción.
///
/// Resultado:
/// - `paint:AARRGGBB,AARRGGBB[;heart|;repeat]`: degradado diagonal (o color
///   liso si solo hay uno) con el ícono opcional encima.
/// - una URL http(s) o una ruta absoluta: la imagen tal cual.
/// - [fallback] (la portada de su primera canción) si no tiene nada propio.
String? nativeCoverSpec(Playlist p, {String? fallback}) {
  if (p.isLiked) return '${_paint(AppTheme.gradientLiked.colors)};heart';
  if (p.isGenerated) return '${_paint(AppTheme.gradientMix.colors)};repeat';
  final cover = p.coverUrl?.trim();
  if (cover == null || cover.isEmpty) return fallback;
  if (cover.startsWith('gradient:')) {
    final index = int.tryParse(cover.substring('gradient:'.length)) ?? 0;
    final presets = PlaylistCoverWidget.presetGradients;
    return _paint(presets[index % presets.length].colors);
  }
  if (cover.startsWith('color:')) {
    final hex = cover.substring('color:'.length).replaceAll('#', '');
    final value = int.tryParse(hex.length == 6 ? 'FF$hex' : hex, radix: 16) ?? 0xFF1DB954;
    return _paint([Color(value)]);
  }
  if (cover.startsWith('http://') || cover.startsWith('https://')) return cover;
  if (isLocalImagePath(cover)) return localImageFilePath(cover);
  return fallback;
}

String _paint(List<Color> colors) =>
    'paint:${colors.map((c) => c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()).join(',')}';
