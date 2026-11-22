import 'package:flutter/services.dart';

/// Una playlist o álbum que el widget de colección puede abrir.
class WidgetCollection {
  const WidgetCollection({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.cover,
  });

  /// `playlist` (id local) o `album` (id de Deezer).
  final String kind;
  final String id;
  final String title;
  final String subtitle;

  /// URL de la portada o ruta local.
  final String? cover;

  Map<String, Object?> toMap() => {
        'kind': kind,
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'cover': cover ?? '',
      };

  @override
  bool operator ==(Object other) =>
      other is WidgetCollection &&
      other.kind == kind &&
      other.id == id &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.cover == cover;

  @override
  int get hashCode => Object.hash(kind, id, title, subtitle, cover);
}

/// Widgets de la pantalla de inicio de Android (ronda 13).
///
/// Todas las llamadas son "mejor esfuerzo": un fallo del lado nativo nunca
/// debe llegar al reproductor.
class SyncoraAndroid {
  SyncoraAndroid._();

  static const _channel = MethodChannel('syncora_android');

  /// El servicio de audio está listo en este proceso: los botones del widget
  /// ya pueden mandarle teclas multimedia en vez de abrir la app.
  static Future<void> playerReady() => _call('playerReady');

  static Future<void> updateNowPlaying({
    required bool hasTrack,
    required String title,
    required String artist,
    String? coverPath,
    required bool playing,
  }) =>
      _call('updateNowPlaying', {
        'hasTrack': hasTrack,
        'title': title,
        'artist': artist,
        'coverPath': coverPath,
        'playing': playing,
      });

  static Future<void> publishLibrary(List<WidgetCollection> items) =>
      _call('publishLibrary', {'items': [for (final i in items) i.toMap()]});

  static Future<bool> isPinSupported() async => await _call<bool>('isPinSupported') ?? false;

  /// Pide al launcher poner un widget de [collection]. `false` si el launcher
  /// no lo permite.
  static Future<bool> pinCollection(WidgetCollection collection) async =>
      await _call<bool>('pinCollection', collection.toMap()) ?? false;

  static Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
