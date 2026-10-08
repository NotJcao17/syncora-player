import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/canonical_version_resolver.dart';
import 'package:syncora_player/data/models/deezer/deezer_album.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';

DeezerTrack _t(int id, String title, {int albumId = 0, String album = '', String? isrc, int dur = 221}) => DeezerTrack(
      id: id,
      title: title,
      artistName: 'Shakira',
      artistId: 160,
      albumTitle: album,
      albumId: albumId,
      coverUrl: 'cover-$albumId',
      durationSec: dur,
      isrc: isrc,
    );

DeezerAlbum _a(int id, String title, String date, {String type = 'album'}) => DeezerAlbum(
      id: id,
      title: title,
      artistName: 'Shakira',
      artistId: 160,
      coverUrl: 'cover-$id',
      trackCount: 0,
      releaseDate: date,
      recordType: type,
    );

/// Datos reales de Deezer (2026-10-08): la búsqueda de "hips don't lie" da
/// la versión de "Filtr presents R&B Party" (Varios Artistas); la misma
/// grabación (mismo ISRC) está en *Oral Fixation, Vol. 2*.
void main() {
  final discography = [
    _a(1048886412, 'Dai Dai', '2026-08-07', type: 'ep'),
    _a(7927764, 'Sale el Sol', '2010-10-19'),
    _a(1422754, 'Shakira MTV Unplugged', '2005-05-24'),
    _a(763994091, 'Fijación Oral Volumen 1', '2005-06-03'),
    _a(763994911, 'Oral Fixation, Vol. 2 (Expanded Edition)', '2005-11-28'),
    _a(1401302, 'Laundry Service', '2001-11-13'),
  ];
  final tracklists = {
    763994911: [
      _t(3389132891, 'Illegal (feat. Carlos Santana)', isrc: 'USSM10506514'),
      _t(3389132901, "Hips Don't Lie (feat. Wyclef Jean)", isrc: 'USSM10600677'),
    ],
    763994091: [_t(1, 'La Tortura', isrc: 'USSM10500001')],
    1422754: [_t(2, 'Pies Descalzos (MTV Unplugged)', isrc: 'USSM10500002')],
  };

  late List<int> albumCalls;
  late int discographyCalls;
  late CanonicalVersionResolver resolver;

  setUp(() {
    albumCalls = [];
    discographyCalls = 0;
    resolver = CanonicalVersionResolver(
      artistAlbums: (id) async {
        discographyCalls++;
        return discography;
      },
      albumTracks: (id) async {
        albumCalls.add(id);
        return tracklists[id] ?? const [];
      },
    );
  });

  test('cambia la versión de una recopilación por la del álbum del artista (mismo ISRC)', () async {
    final compilation = _t(88897841, "Hips Don't Lie (feat. Wyclef Jean)",
        albumId: 8985885, album: 'Filtr presents R&B Party', isrc: 'USSM10600677');
    final result = await resolver.resolve(compilation);
    expect(result.id, 3389132901);
    expect(result.albumId, 763994911);
    expect(result.albumTitle, 'Oral Fixation, Vol. 2 (Expanded Edition)');
    expect(result.coverUrl, 'cover-763994911');
    expect(result.artistName, 'Shakira');
  });

  test('no toca una pista que ya es de un álbum del artista (sin pedir tracklists)', () async {
    final own = _t(79589198, 'Waka Waka (Esto Es Africa) K-Mix', albumId: 7927764, isrc: 'USSD11000359');
    expect(identical(await resolver.resolve(own), own), isTrue);
    expect(albumCalls, isEmpty);
  });

  test('sin el mismo ISRC en la discografía, se queda la original', () async {
    final waka = _t(68473089, 'Waka Waka (This Time for Africa)',
        albumId: 6706046, album: 'Party Hits: Summer Edition', isrc: 'USSD11000300', dur: 203);
    expect(identical(await resolver.resolve(waka), waka), isTrue);
    expect(albumCalls.length, lessThanOrEqualTo(CanonicalVersionResolver.maxAlbumLookups));
  });

  test('sin ISRC no hace ninguna petición', () async {
    final noIsrc = _t(5, 'X', albumId: 99);
    expect(identical(await resolver.resolve(noIsrc), noIsrc), isTrue);
    expect(discographyCalls, 0);
  });

  test('busca primero en los lanzamientos del año del ISRC, álbumes antes que EP, sin discos en vivo', () {
    final ordered = CanonicalVersionResolver.orderCandidateAlbums(discography, 'USSM10600677', excludeAlbumId: 0);
    expect(ordered.take(2).map((a) => a.id), [763994091, 763994911]);
    expect(ordered.map((a) => a.id), isNot(contains(1422754)), reason: 'MTV Unplugged es en vivo');
    expect(ordered.last.id, 1048886412);
  });

  test('un sencillo del propio artista (álbum = canción) no gasta peticiones', () async {
    final cover = DeezerTrack(
      id: 4010409521,
      title: 'Waka Waka',
      artistName: 'Bongo Cat',
      artistId: 77,
      albumTitle: 'Waka Waka',
      albumId: 978792581,
      coverUrl: '',
      durationSec: 135,
      isrc: 'QZN882419024',
    );
    expect(identical(await resolver.resolve(cover), cover), isTrue);
    expect(discographyCalls, 0);
  });

  test('resolveTop reemplaza en su sitio y quita el duplicado que aparece más abajo', () async {
    final compilation = _t(88897841, "Hips Don't Lie", albumId: 8985885, isrc: 'USSM10600677');
    final other = _t(14896962, "Hips Don't Lie (Live)", albumId: 1373817);
    final original = _t(3389132901, "Hips Don't Lie (feat. Wyclef Jean)", albumId: 763994911, isrc: 'USSM10600677');
    final out = await resolver.resolveTop([compilation, other, original], limit: 2);
    expect(out.map((t) => t.id), [3389132901, 14896962]);
  });

  test('un fallo de red no se queda en caché', () async {
    var fail = true;
    final flaky = CanonicalVersionResolver(
      artistAlbums: (id) async {
        if (fail) throw Exception('sin red');
        return discography;
      },
      albumTracks: (id) async => tracklists[id] ?? const [],
    );
    final compilation = _t(88897841, "Hips Don't Lie", albumId: 8985885, isrc: 'USSM10600677');
    expect((await flaky.resolve(compilation)).id, 88897841);
    fail = false;
    expect((await flaky.resolve(compilation)).id, 3389132901);
  });

  test('mayChange: deja de marcarla en cuanto se resolvió', () async {
    final compilation = _t(88897841, "Hips Don't Lie", albumId: 8985885, isrc: 'USSM10600677');
    expect(resolver.pendingIds([compilation]), {88897841});
    final resolved = await resolver.resolve(compilation);
    expect(resolver.mayChange(compilation), isFalse);
    expect(resolver.mayChange(resolved), isFalse);
    expect(resolver.mayChange(_t(5, 'X', albumId: 99)), isFalse, reason: 'sin ISRC');
  });

  test('isrcYear lee el año de registro', () {
    expect(CanonicalVersionResolver.isrcYear('USSM10600677'), 2006);
    expect(CanonicalVersionResolver.isrcYear('GBAYE8500001'), 1985);
  });
}
