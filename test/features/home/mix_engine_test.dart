import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/models/deezer/deezer_album.dart';
import 'package:syncora_player/features/home/mixes/mix_engine.dart';

ListeningHistoryData entry({
  required int trackId,
  int artistId = 1,
  int albumId = 1,
  required DateTime at,
}) =>
    ListeningHistoryData(
      id: trackId * 1000 + at.millisecondsSinceEpoch % 1000,
      trackId: trackId,
      artistId: artistId,
      albumId: albumId,
      listenedAt: at,
      durationListenedMs: 180000,
    );

DeezerAlbum album(String title, String releaseDate, {int artistId = 1}) => DeezerAlbum(
      id: title.hashCode.abs(),
      title: title,
      artistName: 'Artista',
      artistId: artistId,
      coverUrl: '',
      trackCount: 10,
      releaseDate: releaseDate,
    );

void main() {
  final now = DateTime(2026, 9, 17, 12);

  group('claves de periodo', () {
    test('dayKey cambia de un día al siguiente y es estable dentro del día', () {
      expect(MixEngine.dayKey(DateTime(2026, 9, 17, 0, 1)), '2026-09-17');
      expect(MixEngine.dayKey(DateTime(2026, 9, 17, 23, 59)), '2026-09-17');
      expect(MixEngine.dayKey(DateTime(2026, 9, 18)), '2026-09-18');
    });

    test('weekKey es la misma toda la semana y cambia el lunes', () {
      // 2026-09-14 es lunes; 2026-09-20, domingo.
      final lunes = MixEngine.weekKey(DateTime(2026, 9, 14));
      final domingo = MixEngine.weekKey(DateTime(2026, 9, 20));
      final lunesSiguiente = MixEngine.weekKey(DateTime(2026, 9, 21));

      expect(lunes, domingo);
      expect(lunesSiguiente, isNot(lunes));
    });

    test('seedFrom es determinista y distinta por periodo', () {
      expect(MixEngine.seedFrom('2026-09-17'), MixEngine.seedFrom('2026-09-17'));
      expect(MixEngine.seedFrom('2026-09-17'), isNot(MixEngine.seedFrom('2026-09-18')));
    });
  });

  group('rankOnRepeatTrackIds', () {
    test('exige al menos 2 escuchas: una sola no es "repetir"', () {
      final entries = [
        entry(trackId: 1, at: now.subtract(const Duration(days: 1))),
        entry(trackId: 2, at: now.subtract(const Duration(days: 1))),
        entry(trackId: 2, at: now.subtract(const Duration(days: 2))),
      ];

      expect(MixEngine.rankOnRepeatTrackIds(entries, now: now), [2]);
    });

    test('ignora escuchas fuera de la ventana de 30 días', () {
      final entries = [
        entry(trackId: 1, at: now.subtract(const Duration(days: 40))),
        entry(trackId: 1, at: now.subtract(const Duration(days: 45))),
        entry(trackId: 2, at: now.subtract(const Duration(days: 2))),
        entry(trackId: 2, at: now.subtract(const Duration(days: 3))),
      ];

      expect(MixEngine.rankOnRepeatTrackIds(entries, now: now), [2]);
    });

    test('ordena por número de escuchas y desempata por la más reciente', () {
      final entries = [
        for (var i = 0; i < 5; i++) entry(trackId: 10, at: now.subtract(Duration(days: i + 5))),
        for (var i = 0; i < 2; i++) entry(trackId: 20, at: now.subtract(Duration(days: i + 10))),
        for (var i = 0; i < 2; i++) entry(trackId: 30, at: now.subtract(Duration(hours: i + 1))),
      ];

      expect(MixEngine.rankOnRepeatTrackIds(entries, now: now), [10, 30, 20]);
    });
  });

  group('rankArtistIds / rankAlbumIds', () {
    test('cuentan solo dentro de la ventana y descartan ids en 0', () {
      final entries = [
        entry(trackId: 1, artistId: 0, albumId: 0, at: now),
        entry(trackId: 2, artistId: 7, albumId: 70, at: now.subtract(const Duration(days: 1))),
        entry(trackId: 3, artistId: 7, albumId: 70, at: now.subtract(const Duration(days: 2))),
        entry(trackId: 4, artistId: 9, albumId: 90, at: now.subtract(const Duration(days: 90))),
      ];

      expect(MixEngine.rankArtistIds(entries, now: now), [7]);
      expect(MixEngine.rankAlbumIds(entries, now: now), [70]);
    });
  });

  group('filterRecentReleases', () {
    test('deja solo lanzamientos de la ventana, ordenados del más nuevo', () {
      final result = MixEngine.filterRecentReleases(
        [
          album('Viejo', '2024-01-01'),
          album('Reciente', '2026-09-10'),
          album('Muy reciente', '2026-09-16'),
        ],
        now: now,
      );

      expect(result.map((a) => a.title), ['Muy reciente', 'Reciente']);
    });

    test('descarta fechas futuras: Deezer publica fichas antes de tiempo', () {
      final result = MixEngine.filterRecentReleases(
        [album('Del futuro', '2026-12-01'), album('Real', '2026-09-01')],
        now: now,
      );

      expect(result.map((a) => a.title), ['Real']);
    });

    test('deduplica el mismo lanzamiento repetido por edición/territorio', () {
      final result = MixEngine.filterRecentReleases(
        [
          album('Mismo Disco', '2026-09-10'),
          album('mismo disco', '2026-09-09'),
          album('Mismo Disco', '2026-09-08', artistId: 2),
        ],
        now: now,
      );

      expect(result.length, 2);
    });

    test('ignora releaseDate vacío o ilegible en vez de reventar', () {
      final result = MixEngine.filterRecentReleases(
        [album('Sin fecha', ''), album('Basura', 'no-es-fecha'), album('Ok', '2026-09-15')],
        now: now,
      );

      expect(result.map((a) => a.title), ['Ok']);
    });
  });

  group('shuffleDeterministic', () {
    test('la misma semilla da siempre el mismo orden', () {
      final items = List.generate(20, (i) => i);
      expect(
        MixEngine.shuffleDeterministic(items, 1234),
        MixEngine.shuffleDeterministic(items, 1234),
      );
    });

    test('semillas distintas dan órdenes distintos', () {
      final items = List.generate(20, (i) => i);
      expect(
        MixEngine.shuffleDeterministic(items, 1),
        isNot(MixEngine.shuffleDeterministic(items, 2)),
      );
    });

    test('no pierde ni duplica elementos, y no muta la lista original', () {
      final items = List.generate(10, (i) => i);
      final shuffled = MixEngine.shuffleDeterministic(items, 99);

      expect(shuffled.toSet(), items.toSet());
      expect(shuffled.length, items.length);
      expect(items, List.generate(10, (i) => i));
    });
  });
}
