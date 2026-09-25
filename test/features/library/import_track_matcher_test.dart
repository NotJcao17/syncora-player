import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/models/deezer/deezer_album.dart';
import 'package:syncora_player/data/models/deezer/deezer_artist.dart';
import 'package:syncora_player/data/models/deezer/deezer_search_result.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/library/import_export/import_track_matcher.dart';
import 'package:syncora_player/features/library/import_export/playlist_import_export_service.dart';

DeezerTrack _t(int id, String title, String artist, String album, int dur, {int artistId = 1, int rank = 100000}) =>
    DeezerTrack(
      id: id,
      title: title,
      artistName: artist,
      artistId: artistId,
      albumTitle: album,
      albumId: 0,
      coverUrl: '',
      durationSec: dur,
      rank: rank,
    );

/// Deezer de mentira con los casos reales que fallaban (ronda 4, H-R4-13).
class _FakeApi extends DeezerApi {
  final Map<String, List<DeezerTrack>> trackSearch = {};
  final Map<String, List<DeezerAlbum>> albumSearch = {};
  final Map<int, DeezerAlbum> albums = {};
  final Map<int, List<DeezerAlbum>> discographies = {};
  final Map<int, List<DeezerTrack>> tops = {};
  final List<DeezerArtist> artistSearch = [];

  @override
  Future<DeezerSearchResult> search(String query, {DeezerSearchType type = DeezerSearchType.all, bool enrich = true}) async {
    switch (type) {
      case DeezerSearchType.album:
        return DeezerSearchResult(albums: albumSearch[query] ?? const []);
      case DeezerSearchType.artist:
        return DeezerSearchResult(artists: artistSearch);
      default:
        return DeezerSearchResult(tracks: trackSearch[query] ?? const []);
    }
  }

  @override
  Future<DeezerAlbum> getAlbum(int id) async => albums[id]!;

  @override
  Future<List<DeezerAlbum>> getArtistAlbums(int id, {int limit = 300}) async => discographies[id] ?? const [];

  @override
  Future<List<DeezerTrack>> getArtistTopTracksExpanded(int id, {int limit = 100}) async => tops[id] ?? const [];
}

DeezerAlbum _album(int id, String title, String artist, int artistId, List<DeezerTrack> tracks) => DeezerAlbum(
      id: id,
      title: title,
      artistName: artist,
      artistId: artistId,
      coverUrl: '',
      trackCount: tracks.length,
      releaseDate: '',
      tracks: tracks,
    );

void main() {
  late _FakeApi api;
  late ImportTrackMatcher matcher;

  setUp(() {
    api = _FakeApi();
    matcher = ImportTrackMatcher(api);
  });

  test('una versión 8-bit con duración casi igual ya no le gana al original', () async {
    api.trackSearch['5 Seconds of Summer No Shame'] = [
      _t(2, 'No Shame (8-Bit 5 Seconds of Summer Emulation)', '8-Bit Arcade', 'By Request, Vol. 71', 193, artistId: 9),
      _t(1, 'No Shame', '5 Seconds Of Summer', 'CALM', 190),
    ];
    final m = await matcher.match(const RawImportTrack(
      title: 'No Shame', artist: '5 Seconds of Summer', album: 'CALM', durationMs: 193000));
    expect(m?.id, 1);
  });

  test('nunca elige a otro artista aunque sea lo único que aparece', () async {
    api.trackSearch['Coldplay Speed of Sound'] = [
      _t(5, 'Speed Of Sound (By Coldplay) (Instrumental Karaoke Version)', 'ZZang KARAOKE', 'x', 287, artistId: 9),
    ];
    final m = await matcher.match(const RawImportTrack(title: 'Speed of Sound', artist: 'Coldplay', durationMs: 287000));
    expect(m, isNull);
  });

  test('prefiere la versión del álbum del archivo sobre la del sencillo', () async {
    api.trackSearch['5 Seconds of Summer Me, Myself & I'] = [
      _t(10, 'Me, Myself & I', '5 Seconds Of Summer', 'Me, Myself & I', 178, rank: 900000),
    ];
    api.albumSearch['5 Seconds of Summer 5SOS5'] = [
      _album(50, '5SOS5', '5 Seconds Of Summer', 1, [
        _t(11, 'Me, Myself & I', '5 Seconds Of Summer', '5SOS5', 178),
        _t(12, 'Older', '5 Seconds Of Summer', '5SOS5', 200),
      ]),
    ];
    api.albums[50] = api.albumSearch['5 Seconds of Summer 5SOS5']!.single;
    final m = await matcher.match(const RawImportTrack(
      title: 'Me, Myself & I', artist: '5 Seconds of Summer', album: '5SOS5', durationMs: 178000));
    expect(m?.id, 11);
  });

  test('artista que no sale en la búsqueda de canciones: lo encuentra por su discografía', () async {
    api.trackSearch['Adele Someone Like You'] = [
      _t(20, 'Someone Like You', "Tonight i'm Adele", 'Karaoke', 285, artistId: 9),
    ];
    api.artistSearch.add(const DeezerArtist(id: 75798, name: 'Adele', pictureUrl: '', nbFan: 1000000));
    api.discographies[75798] = [
      _album(21, '21', 'Artista Desconocido', 0, const []),
    ];
    api.albums[21] = _album(21, '21', 'Adele', 75798, [
      _t(21, 'Rolling in the Deep', 'Adele', '21', 228, artistId: 75798),
      _t(22, 'Someone Like You', 'Adele', '21', 285, artistId: 75798),
    ]);
    final m = await matcher.match(const RawImportTrack(
      title: 'Someone Like You', artist: 'Adele', album: '21', durationMs: 285000));
    expect(m?.id, 22);
  });

  test('una regrabación con sufijo no reemplaza al título exacto', () async {
    api.trackSearch['Jesse & Joy ¿Con Quién Se Queda El Perro?'] = [
      _t(30, '¿Con Quién Se Queda El Perro?', 'Jesse & Joy', 'Otro', 188),
      _t(31, '¿Con Quién Se Queda El Perro? (The Warner Sound)', 'Jesse & Joy', '¿Con Quién Se Queda El Perro? (Deluxe)', 190),
    ];
    final m = await matcher.match(const RawImportTrack(
      title: '¿Con Quién Se Queda El Perro?', artist: 'Jesse & Joy', album: '¿Con Quién Se Queda El Perro?', durationMs: 188306));
    expect(m?.id, 30);
  });

  test('normaliza el formato de Spotify ("feat." y " - Remix") contra el de Deezer', () {
    expect(
      ImportTrackMatcher.normalizeTitle('Dancin (feat. Luvli) - Krono Remix'),
      ImportTrackMatcher.normalizeTitle('Dancin (Krono Remix)'),
    );
    expect(ImportTrackMatcher.normalizeName('The Weeknd'), ImportTrackMatcher.normalizeName('Weeknd'));
    expect(ImportTrackMatcher.normalizeAlbum('Youngblood (Deluxe)'), ImportTrackMatcher.normalizeAlbum('Youngblood'));
  });
}
