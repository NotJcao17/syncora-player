import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cache/app_image_cache.dart';
import '../utils/local_image_path.dart';
import '../storage/app_storage.dart';

/// Qué se está subiendo. Define el tamaño final de la imagen.
enum CustomImageKind {
  playlistCover(640),
  avatar(320);

  final int size;
  const CustomImageKind(this.size);
}

/// Error con un mensaje ya listo para mostrar al usuario.
class CustomImageException implements Exception {
  final String message;
  const CustomImageException(this.message);

  @override
  String toString() => 'CustomImageException($message)';
}

/// Firma de la llamada a la Edge Function, inyectable en tests.
typedef ImageFunctionInvoker = Future<FunctionResponse> Function(
  String functionName, {
  Object? body,
  Map<String, dynamic>? queryParameters,
});

/// Portadas propias de playlists y foto de perfil
/// (`docs/fases/portadas_y_fotos.md`).
///
/// Toda imagen pasa por [processImage] antes de guardarse o subirse: recorte
/// cuadrado, tamaño fijo y JPEG sin metadatos. En modo local se queda en
/// `Documents/syncora/custom_images/`; con cuenta se sube a Cloudflare R2 por
/// la Edge Function `user-images`, que es la única que tiene las llaves.
class CustomImageService {
  static const _functionName = 'user-images';

  /// Tope del archivo original; una foto de móvil ronda los 3-8 MB.
  static const maxSourceBytes = 30 * 1024 * 1024;

  /// Fondo para imágenes con transparencia (JPEG no la admite): el de la app.
  static const _backgroundArgb = 0xFF181C27;

  final ImageFunctionInvoker _invoke;

  CustomImageService({ImageFunctionInvoker? invoke}) : _invoke = invoke ?? _defaultInvoke;

  static Future<FunctionResponse> _defaultInvoke(
    String functionName, {
    Object? body,
    Map<String, dynamic>? queryParameters,
  }) {
    return Supabase.instance.client.functions.invoke(
      functionName,
      body: body,
      queryParameters: queryParameters,
    );
  }

  /// Abre el selector de imágenes del sistema. `null` si el usuario cancela.
  Future<Uint8List?> pickImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: kIsWeb);
    final file = result?.files.singleOrNull;
    if (file == null) return null;
    if (file.size > maxSourceBytes) {
      throw const CustomImageException('La imagen es demasiado grande (máximo 30 MB).');
    }
    final bytes = file.bytes ?? (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) throw const CustomImageException('No se pudo leer la imagen.');
    return bytes;
  }

  /// Recorte cuadrado y JPEG listo para guardar o subir.
  ///
  /// Ronda 6: decodificar la foto entera con el paquete `image` (aunque fuera
  /// en un isolate) congelaba la app en Android hasta el "no responde". Una
  /// foto de 12 MP son ~50 MB por copia y el proceso hace varias; los isolates
  /// de `compute` comparten el recolector de basura con el principal, que en
  /// Android (Flutter 3.29+) es el mismo hilo que recibe los toques. Ahora la
  /// decodifica el códec nativo del motor, ya reducida al tamaño final, y en
  /// Dart solo se codifica el JPEG pequeño. [processImage] queda de respaldo
  /// para formatos que el motor no lea.
  Future<Uint8List> prepare(Uint8List source, CustomImageKind kind) async {
    try {
      final square = await _decodeSquare(source, kind.size);
      return await compute(_encodeJpeg, square);
    } catch (_) {
      // Formato que el códec del motor no lee: camino anterior.
    }
    try {
      return await compute(_processInIsolate, (source, kind.size));
    } on CustomImageException {
      rethrow;
    } catch (_) {
      throw const CustomImageException('No se pudo procesar la imagen.');
    }
  }

  static Uint8List _processInIsolate((Uint8List, int) args) => processImage(args.$1, args.$2);

  /// Decodifica con el motor (reduce mientras decodifica y aplica la
  /// orientación del EXIF) y devuelve el recorte cuadrado centrado de lado
  /// `min(size, lado corto)` en RGBA, sobre el fondo de la app.
  static Future<({Uint8List rgba, int side})> _decodeSquare(Uint8List source, int size) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(source);
    // Solo el ancho: el códec conserva la proporción, así que da igual si la
    // foto viene girada por EXIF.
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      final shortest = min(w, h);
      return shortest <= size ? const ui.TargetImageSize() : ui.TargetImageSize(width: (w * size / shortest).ceil());
    });
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    try {
      final side = min(image.width, image.height);
      final target = min(size, side);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
        ..drawColor(const ui.Color(_backgroundArgb), ui.BlendMode.src)
        ..drawImageRect(
          image,
          ui.Rect.fromLTWH((image.width - side) / 2, (image.height - side) / 2, side.toDouble(), side.toDouble()),
          ui.Rect.fromLTWH(0, 0, target.toDouble(), target.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.high,
        );
      final picture = recorder.endRecording();
      final out = await picture.toImage(target, target);
      picture.dispose();
      try {
        final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) throw const CustomImageException('No se pudo procesar la imagen.');
        return (rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), side: target);
      } finally {
        out.dispose();
      }
    } finally {
      image.dispose();
    }
  }

  /// JPEG calidad 85 de un RGBA ya pequeño. Sin EXIF: el bitmap no lo tiene.
  static Uint8List _encodeJpeg(({Uint8List rgba, int side}) args) {
    final image = img.Image.fromBytes(
      width: args.side,
      height: args.side,
      bytes: args.rgba.buffer,
      bytesOffset: args.rgba.offsetInBytes,
      numChannels: 4,
    );
    return img.encodeJpg(image, quality: 85);
  }

  /// Recorte cuadrado centrado, lado [size] (sin ampliar las pequeñas), JPEG
  /// calidad 85 y **sin EXIF**: se descartan ubicación GPS, cámara, fecha, etc.
  @visibleForTesting
  static Uint8List processImage(Uint8List source, int size) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(source);
    } catch (_) {
      decoded = null;
    }
    if (decoded == null) {
      throw const CustomImageException('Formato no compatible. Usa una imagen JPG, PNG o WebP.');
    }
    // Las fotos de móvil guardan la rotación en el EXIF; se aplica antes de
    // tirarlo, o la imagen quedaría de lado.
    final oriented = img.bakeOrientation(decoded);
    final side = min(oriented.width, oriented.height);
    final target = min(size, side);
    final cropped = img.copyCrop(
      oriented,
      x: (oriented.width - side) ~/ 2,
      y: (oriented.height - side) ~/ 2,
      width: side,
      height: side,
    );
    var result = img.copyResize(
      cropped,
      width: target,
      height: target,
      interpolation: img.Interpolation.average,
    );
    if (result.hasAlpha) {
      final background = img.Image(width: target, height: target)
        ..clear(img.ColorRgb8(
          (_backgroundArgb >> 16) & 0xFF,
          (_backgroundArgb >> 8) & 0xFF,
          _backgroundArgb & 0xFF,
        ));
      result = img.compositeImage(background, result);
    }
    result.exif = img.ExifData();
    return img.encodeJpg(result, quality: 85);
  }

  static String? _cachedDir;

  Future<Directory> _localDir() async {
    final cached = _cachedDir;
    if (cached != null) return Directory(cached);
    final base = (await appDataDirectory()).path;
    final dir = Directory(p.join(base, 'syncora', 'custom_images'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cachedDir = dir.path;
    return dir;
  }

  /// Guarda la imagen en el dispositivo y devuelve su ruta absoluta. Nombre
  /// nuevo cada vez: la caché de imágenes de Flutter va por ruta, y
  /// reutilizarla mostraría la imagen anterior.
  Future<String> saveLocal(Uint8List jpeg) async {
    final dir = await _localDir();
    final file = File(p.join(dir.path, '${_randomName()}.jpg'));
    await file.writeAsBytes(jpeg, flush: true);
    return file.path;
  }

  /// Borra una imagen guardada por [saveLocal]. Cualquier otra ruta (por
  /// ejemplo, la portada de una descarga) se ignora.
  Future<void> deleteLocal(String? path) async {
    if (path == null || !isLocalImagePath(path)) return;
    try {
      final dir = await _localDir();
      final file = File(localImageFilePath(path));
      if (!p.isWithin(dir.path, file.path)) return;
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // Un archivo huérfano de ~100 KB no justifica un error visible.
    }
  }

  /// Borra todas las imágenes propias del dispositivo (al descartar la
  /// biblioteca local o eliminar la cuenta).
  Future<void> deleteAllLocal() async {
    try {
      final dir = await _localDir();
      if (dir.existsSync()) await dir.delete(recursive: true);
      _cachedDir = null;
    } catch (_) {}
  }

  /// Sube la imagen a R2 y devuelve su URL pública. [playlistRemoteId] es
  /// obligatorio para portadas. La URL todavía no está guardada en ninguna
  /// fila: eso lo hace quien llama, con su JWT.
  Future<String> upload(Uint8List jpeg, CustomImageKind kind, {String? playlistRemoteId}) async {
    final query = <String, dynamic>{
      'action': 'upload',
      'kind': kind == CustomImageKind.avatar ? 'avatar' : 'playlist',
      if (kind == CustomImageKind.playlistCover) 'playlist_id': playlistRemoteId,
    };
    final FunctionResponse response;
    try {
      response = await _invoke(_functionName, body: jpeg, queryParameters: query);
    } on FunctionException catch (e) {
      throw _mapFunctionException(e);
    } catch (_) {
      throw const CustomImageException('No se pudo subir la imagen. Revisa tu conexión e intenta de nuevo.');
    }

    final data = response.data;
    final url = data is Map ? data['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const CustomImageException('El servidor devolvió una respuesta inesperada.');
    }
    // Ya tenemos los bytes: se guardan en la caché de portadas para que la
    // imagen aparezca al instante y siga viéndose sin conexión.
    try {
      await AppImageCache.instance.putFile(url, jpeg, fileExtension: 'jpg');
    } catch (_) {}
    return url;
  }

  /// Pide al servidor que borre las imágenes que ya nada referencia. Se
  /// llama después de quitar una portada o borrar una playlist; si falla, la
  /// siguiente subida limpia igual.
  Future<void> collectGarbage() async {
    try {
      await _invoke(_functionName, queryParameters: {'action': 'gc'});
    } catch (_) {}
  }

  /// Borra todas las imágenes de la cuenta en R2. Antes de eliminarla.
  Future<void> deleteAllRemote() async {
    await _invoke(_functionName, queryParameters: {'action': 'delete_all'});
  }

  CustomImageException _mapFunctionException(FunctionException e) {
    final details = e.details;
    final message = details is Map ? details['message'] : null;
    if (message is String && message.isNotEmpty) return CustomImageException(message);
    return const CustomImageException('No se pudo subir la imagen. Intenta de nuevo más tarde.');
  }

  static String _randomName() {
    final rand = Random.secure();
    return List.generate(12, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

final customImageServiceProvider = Provider<CustomImageService>((ref) => CustomImageService());
