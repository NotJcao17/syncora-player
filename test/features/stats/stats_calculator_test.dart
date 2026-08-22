import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/stats/stats_calculator.dart';

void main() {
  group('weekCutoff/monthCutoff', () {
    test('weekCutoff excluye entradas de hace más de 7 días', () {
      final now = DateTime.utc(2026, 8, 22);
      final cutoff = weekCutoff(now);
      final justInside = now.subtract(const Duration(days: 6, hours: 23));
      final justOutside = now.subtract(const Duration(days: 7, hours: 1));

      expect(justInside.isAfter(cutoff), isTrue);
      expect(justOutside.isBefore(cutoff), isTrue);
    });

    test('monthCutoff excluye entradas de hace más de 30 días', () {
      final now = DateTime.utc(2026, 8, 22);
      final cutoff = monthCutoff(now);
      final justInside = now.subtract(const Duration(days: 29));
      final justOutside = now.subtract(const Duration(days: 31));

      expect(justInside.isAfter(cutoff), isTrue);
      expect(justOutside.isBefore(cutoff), isTrue);
    });
  });

  group('StatsCalculator.fromRawEntries', () {
    test('suma minutos totales y agrega por artista/canción/género', () {
      final entries = [
        const RawListenEntry(artistId: 1, trackId: 10, genre: 'Pop', durationListenedMs: 180000),
        const RawListenEntry(artistId: 1, trackId: 11, genre: 'Pop', durationListenedMs: 120000),
        const RawListenEntry(artistId: 2, trackId: 12, genre: 'Rock', durationListenedMs: 60000),
      ];

      final snapshot = StatsCalculator.fromRawEntries(entries, topN: 5);

      expect(snapshot.totalMinutes, 6);
      expect(snapshot.topArtists.first.id, 1);
      expect(snapshot.topArtists.first.minutes, 5);
      expect(snapshot.topArtists.first.playCount, 2);
      expect(snapshot.topTracks.length, 3);
      expect(snapshot.topGenres.first.genre, 'Pop');
      expect(snapshot.topGenres.first.minutes, 5);
    });

    test('respeta topN: recorta si hay más, no rellena si hay menos', () {
      final entries = List.generate(
        8,
        (i) => RawListenEntry(artistId: i + 1, trackId: i + 100, durationListenedMs: 60000),
      );

      final top3 = StatsCalculator.fromRawEntries(entries, topN: 3);
      expect(top3.topArtists.length, 3);

      final onlyTwoEntries = entries.take(2).toList();
      final top5 = StatsCalculator.fromRawEntries(onlyTwoEntries, topN: 5);
      expect(top5.topArtists.length, 2);
    });

    test('lista vacía produce snapshot vacío sin errores', () {
      final snapshot = StatsCalculator.fromRawEntries(const [], topN: 5);
      expect(snapshot.isEmpty, isTrue);
      expect(snapshot.totalMinutes, 0);
    });

    test('ignora artistId/trackId 0 (sin id válido) pero suma género y minutos totales', () {
      final entries = [
        const RawListenEntry(artistId: 0, trackId: 0, genre: 'Pop', durationListenedMs: 60000),
      ];
      final snapshot = StatsCalculator.fromRawEntries(entries, topN: 5);
      expect(snapshot.topArtists, isEmpty);
      expect(snapshot.topTracks, isEmpty);
      expect(snapshot.totalMinutes, 1);
      expect(snapshot.topGenres.single.minutes, 1);
    });
  });

  group('StatsCalculator.rollupMonthlyRows', () {
    MonthlyStatsRow rowFor(int month, {required int totalMinutes, required List<StatEntry> artists}) {
      return MonthlyStatsRow(
        monthStart: DateTime.utc(2026, month, 1),
        totalMinutes: totalMinutes,
        topArtists: artists,
        topTracks: const [],
        topGenres: const [GenreEntry(genre: 'Pop', minutes: 10)],
      );
    }

    test('suma minutos de 12 filas mensuales, mismo artista en varios meses se suma sin duplicar', () {
      final rows = [
        rowFor(1, totalMinutes: 100, artists: const [StatEntry(id: 1, minutes: 50)]),
        rowFor(2, totalMinutes: 200, artists: const [StatEntry(id: 1, minutes: 30), StatEntry(id: 2, minutes: 20)]),
        rowFor(3, totalMinutes: 150, artists: const [StatEntry(id: 1, minutes: 40)]),
        for (var m = 4; m <= 12; m++) rowFor(m, totalMinutes: 10, artists: const [StatEntry(id: 3, minutes: 5)]),
      ];

      final snapshot = StatsCalculator.rollupMonthlyRows(rows, topN: 10);

      expect(rows.length, 12);
      expect(snapshot.totalMinutes, 100 + 200 + 150 + 9 * 10);
      final artist1 = snapshot.topArtists.firstWhere((a) => a.id == 1);
      expect(artist1.minutes, 50 + 30 + 40);
      expect(snapshot.topArtists.where((a) => a.id == 1).length, 1);
    });

    test('menos de 12 meses de historial funciona igual, sin relleno artificial', () {
      final rows = [
        rowFor(1, totalMinutes: 100, artists: const [StatEntry(id: 1, minutes: 50)]),
        rowFor(2, totalMinutes: 80, artists: const [StatEntry(id: 2, minutes: 40)]),
        rowFor(3, totalMinutes: 60, artists: const [StatEntry(id: 1, minutes: 20)]),
        rowFor(4, totalMinutes: 40, artists: const [StatEntry(id: 3, minutes: 10)]),
      ];

      final snapshot = StatsCalculator.rollupMonthlyRows(rows, topN: 10);

      expect(snapshot.totalMinutes, 280);
      expect(snapshot.topArtists, isNotEmpty);
      expect(snapshot.isEmpty, isFalse);
    });

    test('mostActiveMonth elige la fila individual de mayor total, no la suma', () {
      final rows = [
        rowFor(1, totalMinutes: 100, artists: const []),
        rowFor(2, totalMinutes: 500, artists: const []),
        rowFor(3, totalMinutes: 300, artists: const []),
      ];

      final snapshot = StatsCalculator.rollupMonthlyRows(rows, topN: 10);

      expect(snapshot.mostActiveMonth, DateTime.utc(2026, 2, 1));
    });

    test('topN recorta el resultado del merge', () {
      final rows = [
        rowFor(
          1,
          totalMinutes: 100,
          artists: List.generate(12, (i) => StatEntry(id: i + 1, minutes: 100 - i)),
        ),
      ];

      final snapshot = StatsCalculator.rollupMonthlyRows(rows, topN: 10);
      expect(snapshot.topArtists.length, 10);
    });

    test('lista vacía de filas produce snapshot vacío sin errores', () {
      final snapshot = StatsCalculator.rollupMonthlyRows(const [], topN: 10);
      expect(snapshot.totalMinutes, 0);
      expect(snapshot.mostActiveMonth, isNull);
    });
  });
}
