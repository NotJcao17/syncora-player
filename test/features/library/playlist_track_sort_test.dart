import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/settings/app_settings_store.dart';
import 'package:syncora_player/features/library/playlist_track_sort.dart';

typedef _T = ({String title, String artist, String album, int sec});

List<_T> _sorted(List<_T> items, PlaylistSort sort) => sortPlaylistItems(
      items,
      sort,
      title: (t) => t.title,
      artist: (t) => t.artist,
      album: (t) => t.album,
      addedAt: (t) => DateTime(2026),
      duration: (t) => Duration(seconds: t.sec),
    );

void main() {
  const items = <_T>[
    (title: 'Feo', artist: 'Morat', album: 'Feo', sec: 177),
    (title: 'Maps', artist: 'Maroon 5', album: 'V', sec: 190),
    (title: '23', artist: 'Morat', album: '23', sec: 187),
    (title: 'Hello', artist: 'Adele', album: '25', sec: 296),
  ];

  test('Agregadas recientemente es el orden original al revés', () {
    expect(_sorted(items, PlaylistSort.recentlyAdded).map((t) => t.title), ['Hello', '23', 'Maps', 'Feo']);
  });

  test('por artista, y dentro del artista por álbum', () {
    expect(_sorted(items, const PlaylistSort(PlaylistSortColumn.artist, PlaylistSortDirection.asc)).map((t) => t.title),
        ['Hello', 'Maps', '23', 'Feo']);
  });

  test('a igualdad se conserva el orden original', () {
    final same = [for (var i = 0; i < 40; i++) (title: 'x$i', artist: 'Morat', album: 'A', sec: 1)];
    expect(_sorted(same, const PlaylistSort(PlaylistSortColumn.artist, PlaylistSortDirection.asc)), same);
  });

  test('tocar columnas: asc, desc, original; "#" alterna con agregadas recientemente', () {
    var s = PlaylistSort.original;
    s = s.tap(PlaylistSortColumn.title);
    expect(s, const PlaylistSort(PlaylistSortColumn.title, PlaylistSortDirection.asc));
    s = s.tap(PlaylistSortColumn.title);
    expect(s.direction, PlaylistSortDirection.desc);
    s = s.tap(PlaylistSortColumn.title);
    expect(s, PlaylistSort.original);
    s = s.tap(PlaylistSortColumn.original);
    expect(s, PlaylistSort.recentlyAdded);
    s = s.tap(PlaylistSortColumn.original);
    expect(s, PlaylistSort.original);
  });

  test('H-R8-9: el orden se guarda por playlist', () async {
    final store = AppSettingsStore.inMemory();
    await savePlaylistSort(store, '7', const PlaylistSort(PlaylistSortColumn.artist, PlaylistSortDirection.desc));
    expect(loadPlaylistSort(store, '7'), const PlaylistSort(PlaylistSortColumn.artist, PlaylistSortDirection.desc));
    expect(loadPlaylistSort(store, '8'), PlaylistSort.original);
    expect(PlaylistSort.decode('basura'), PlaylistSort.original);
  });
}
