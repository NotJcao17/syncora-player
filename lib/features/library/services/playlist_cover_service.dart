import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/images/custom_image_service.dart';
import '../../../core/utils/local_image_path.dart';
import '../../../data/local_db/syncora_database.dart';

/// ¿La portada es una imagen (URL o archivo) y no un degradado, un color o
/// la cuadrícula automática?
bool isImageCover(String? cover) =>
    cover != null && cover.isNotEmpty && !cover.startsWith('gradient:') && !cover.startsWith('color:');

/// Libera la imagen de una portada que ya no se usa: borra el archivo si era
/// local y pide al servidor que recoja la subida si estaba en la nube.
///
/// Se llama tras cambiar la portada o borrar la playlist. No bloquea ni falla:
/// si algo queda colgado, la siguiente limpieza lo recoge.
void releaseCoverImage(WidgetRef ref, Playlist playlist, {String? replacedBy}) {
  final old = playlist.coverUrl;
  if (!isImageCover(old) || old == replacedBy) return;
  final service = ref.read(customImageServiceProvider);
  if (isLocalImagePath(old!)) {
    unawaited(service.deleteLocal(old));
  } else if (playlist.remoteId != null) {
    unawaited(service.collectGarbage());
  }
}
