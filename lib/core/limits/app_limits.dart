import 'package:flutter/material.dart';

/// Límites de contenido de la app (ronda 5).
///
/// Los de texto siguen a los de Spotify (nombre de playlist 100, descripción
/// 300). El de canciones protege la base de datos del plan gratis: una fila de
/// `playlist_tracks` pesa ~400 bytes, así que 10 000 son ~4 MB, varias veces
/// lo que pesa un usuario típico entero (Documento Maestro §4.2).
///
/// La app los aplica antes de escribir; la migración 21 los repite en
/// Supabase (con margen en los de texto) como respaldo.
abstract final class AppLimits {
  static const int playlistTitleMax = 100;
  static const int playlistDescriptionMax = 300;
  static const int playlistTracksMax = 10000;
  static const int folderNameMax = 100;

  /// Mensaje cuando una playlist ya no admite más canciones.
  static const String playlistFullMessage = 'La playlist llegó al máximo de 10 000 canciones';

  static String clampTitle(String value) => _clamp(value.trim(), playlistTitleMax);

  static String? clampDescription(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? trimmed : _clamp(trimmed, playlistDescriptionMax);
  }

  static String _clamp(String value, int max) {
    if (value.characters.length <= max) return value;
    return value.characters.take(max).toString().trimRight();
  }

  /// Cuántas canciones caben todavía en una playlist que ya tiene [current].
  static int roomFor(int current) => (playlistTracksMax - current).clamp(0, playlistTracksMax);

  /// ¿El error viene del límite de canciones que aplica Supabase?
  static bool isTrackLimitError(Object error) => error.toString().contains('playlist_track_limit');

  /// Contador de un campo de texto que solo aparece cerca del límite: el
  /// "0/100" fijo bajo cada campo era ruido.
  static Widget? quietCounter(
    BuildContext context, {
    required int currentLength,
    required int? maxLength,
    required bool isFocused,
  }) {
    if (maxLength == null || currentLength < maxLength * 0.8) return null;
    return Text(
      '$currentLength/$maxLength',
      style: TextStyle(
        fontSize: 11,
        color: currentLength >= maxLength ? Colors.redAccent : const Color(0xFF7F8C9D),
      ),
    );
  }
}
