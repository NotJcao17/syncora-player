import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Carpeta raíz de los datos de la app: base local, cachés, descargas,
/// portadas, importaciones e imágenes propias.
///
/// - **Windows:** `%LOCALAPPDATA%\com.syncora\Syncora Player`. Antes todo iba a
///   la carpeta Documentos del usuario, donde se veía como basura suelta
///   (`syncora_local.sqlite`, `api_cache`…) y la compartían el build de
///   desarrollo y el instalado. `LocalAppData` y no `Roaming` porque las
///   descargas pesan y no deben viajar con perfiles móviles; `%temp%` es otra
///   carpeta y limpiarla no toca nada de esto. Se obtiene con
///   `getApplicationCacheDirectory`, que en Windows es justo esa ruta: el
///   nombre del método no significa que sean datos desechables.
/// - **Android y el resto:** la carpeta de documentos de la app, que en Android
///   ya es privada. Sin cambios respecto a antes.
///
/// La sesión del reproductor, el motor y los ajustes siguen en
/// `getApplicationSupportDirectory` (Roaming en Windows), como siempre.
Future<Directory> appDataDirectory() async {
  final cached = _cached;
  if (cached != null) return cached;
  final dir = (!kIsWeb && Platform.isWindows)
      ? await getApplicationCacheDirectory()
      : await getApplicationDocumentsDirectory();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return _cached = dir;
}

Directory? _cached;
