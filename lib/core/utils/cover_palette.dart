import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:palette_generator/palette_generator.dart';

/// Paleta de colores de una portada, barata y memorizada (ronda 4).
///
/// `PaletteGenerator` cuantiza los píxeles **en el hilo de la UI**. Con la
/// portada a tamaño completo (y en algunas pantallas bajándola otra vez con
/// `NetworkImage`, sin caché) eso costaba del orden de 100 ms justo al abrir
/// una playlist, un álbum o el reproductor: el tirón al entrar. Aquí la imagen
/// se decodifica a 64x64 (para sacar un color de fondo sobra) desde la caché
/// de `CachedNetworkImage`, y el resultado se guarda por URL: volver a abrir
/// la misma pantalla ya no calcula nada.
class CoverPalette {
  CoverPalette._();

  static final Map<String, PaletteGenerator> _cache = {};
  static const _maxEntries = 120;

  static Future<PaletteGenerator?> of(String url) async {
    if (url.isEmpty) return null;
    final cached = _cache[url];
    if (cached != null) return cached;

    final ImageProvider base = (url.startsWith('file://') || url.startsWith('/'))
        ? FileImage(File(url.replaceFirst('file://', '')))
        : CachedNetworkImageProvider(url);
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        ResizeImage(base, width: 64, height: 64),
        maximumColorCount: 8,
      );
      if (_cache.length >= _maxEntries) _cache.remove(_cache.keys.first);
      _cache[url] = palette;
      return palette;
    } catch (_) {
      return null;
    }
  }
}
