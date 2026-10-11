import '../../core/settings/app_settings_store.dart';

enum PlaylistSortColumn { original, title, artist, album, date, duration }

enum PlaylistSortDirection { asc, desc, none }

/// Orden de las canciones dentro de una playlist (ronda 8).
///
/// "Agregadas recientemente" es el orden original al revés (columna
/// `original`, dirección `desc`): en una playlist importada todas las pistas
/// comparten la fecha de agregado, así que ordenar por fecha no sirve.
class PlaylistSort {
  const PlaylistSort(this.column, this.direction);

  final PlaylistSortColumn column;
  final PlaylistSortDirection direction;

  static const original = PlaylistSort(PlaylistSortColumn.original, PlaylistSortDirection.none);
  static const recentlyAdded = PlaylistSort(PlaylistSortColumn.original, PlaylistSortDirection.desc);

  bool get isRecentlyAdded => column == PlaylistSortColumn.original && direction == PlaylistSortDirection.desc;

  /// Sin orden propio: el de la playlist.
  bool get isOriginal => this == original || (column != PlaylistSortColumn.original && direction == PlaylistSortDirection.none);

  /// Columna activa para pintar la flecha (ninguna en el orden original).
  bool isSortedBy(PlaylistSortColumn c) =>
      !isOriginal && column == c && direction != PlaylistSortDirection.none;

  /// Tocar una columna: ascendente → descendente → orden original. En la
  /// columna "#" alterna entre el orden original y "Agregadas recientemente".
  PlaylistSort tap(PlaylistSortColumn tapped) {
    if (tapped == PlaylistSortColumn.original) return isRecentlyAdded ? original : recentlyAdded;
    if (column != tapped || isOriginal) return PlaylistSort(tapped, PlaylistSortDirection.asc);
    if (direction == PlaylistSortDirection.asc) return PlaylistSort(tapped, PlaylistSortDirection.desc);
    return original;
  }

  String encode() => '${column.name}|${direction.name}';

  static PlaylistSort decode(String? raw) {
    if (raw == null) return original;
    final parts = raw.split('|');
    if (parts.length != 2) return original;
    final column = PlaylistSortColumn.values.where((c) => c.name == parts[0]).firstOrNull;
    final direction = PlaylistSortDirection.values.where((d) => d.name == parts[1]).firstOrNull;
    if (column == null || direction == null) return original;
    return PlaylistSort(column, direction);
  }

  @override
  bool operator ==(Object other) =>
      other is PlaylistSort && other.column == column && other.direction == direction;

  @override
  int get hashCode => Object.hash(column, direction);
}

/// Ordena [items] según [sort]. A igualdad conserva el orden original (el
/// `sort` de Dart no es estable).
List<T> sortPlaylistItems<T>(
  List<T> items,
  PlaylistSort sort, {
  required String Function(T) title,
  required String Function(T) artist,
  required String Function(T) album,
  required DateTime Function(T) addedAt,
  required Duration Function(T) duration,
}) {
  if (sort.isRecentlyAdded) return items.reversed.toList();
  if (sort.isOriginal || sort.column == PlaylistSortColumn.original) return items;

  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  int compare(T a, T b) {
    switch (sort.column) {
      case PlaylistSortColumn.title:
        return title(a).toLowerCase().compareTo(title(b).toLowerCase());
      case PlaylistSortColumn.artist:
        final byArtist = artist(a).toLowerCase().compareTo(artist(b).toLowerCase());
        return byArtist != 0 ? byArtist : album(a).toLowerCase().compareTo(album(b).toLowerCase());
      case PlaylistSortColumn.album:
        return album(a).toLowerCase().compareTo(album(b).toLowerCase());
      case PlaylistSortColumn.date:
        return addedAt(a).compareTo(addedAt(b));
      case PlaylistSortColumn.duration:
        return duration(a).compareTo(duration(b));
      case PlaylistSortColumn.original:
        return 0;
    }
  }

  final sign = sort.direction == PlaylistSortDirection.desc ? -1 : 1;
  indexed.sort((x, y) {
    final c = compare(x.$2, y.$2) * sign;
    return c != 0 ? c : x.$1.compareTo(y.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// El orden elegido se guarda por playlist y por dispositivo, como el resto de
/// ajustes de vista.
String playlistSortKey(String playlistId) => 'playlist.sort.$playlistId';

PlaylistSort loadPlaylistSort(AppSettingsStore store, String playlistId) =>
    PlaylistSort.decode(store.getString(playlistSortKey(playlistId)));

Future<void> savePlaylistSort(AppSettingsStore store, String playlistId, PlaylistSort sort) =>
    store.setString(playlistSortKey(playlistId), sort.encode());
