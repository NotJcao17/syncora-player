import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/supabase/supabase_stats_repository.dart';
import 'package:syncora_player/features/stats/stats_calculator.dart';
import 'package:syncora_player/features/stats/stats_models.dart';

/// El cálculo existe por duplicado: en Postgres (`get_listening_stats`, que
/// es lo que se usa con cuenta) y en Dart (`StatsCalculator`, modo local).
/// Tienen que dar lo mismo sobre los mismos datos, y eso es lo que fija el
/// grupo "paridad con el RPC": el JSON de ese test es la RESPUESTA REAL del
/// RPC contra Postgres para las cuatro escuchas de abajo, copiada tal cual.
void main() {
  RawListenEntry e({
    required int trackId,
    required int artistId,
    required int albumId,
    String? genre,
    required int ms,
    required DateTime at,
  }) =>
      RawListenEntry(
        trackId: trackId,
        artistId: artistId,
        albumId: albumId,
        genre: genre,
        durationListenedMs: ms,
        listenedAt: at,
      );

  /// Las mismas cuatro escuchas que se insertaron en Supabase para generar
  /// el JSON de referencia.
  List<RawListenEntry> muestra() => [
        e(
            trackId: 1,
            artistId: 100,
            albumId: 900,
            genre: 'Rock',
            ms: 180000,
            at: DateTime.utc(2026, 9, 18, 15)),
        e(
            trackId: 2,
            artistId: 100,
            albumId: 900,
            genre: 'Rock',
            ms: 120000,
            at: DateTime.utc(2026, 9, 18, 16)),
        e(
            trackId: 1,
            artistId: 100,
            albumId: 900,
            genre: 'Rock',
            ms: 60000,
            at: DateTime.utc(2026, 9, 19, 15)),
        e(
            trackId: 3,
            artistId: 200,
            albumId: 901,
            genre: 'Pop',
            ms: 240000,
            at: DateTime.utc(2026, 9, 20, 10)),
      ];

  group('fromRawEntries', () {
    test('totales y conteos', () {
      final s = StatsCalculator.fromRawEntries(muestra(), bucket: StatsBucket.day);

      expect(s.totalMs, 600000);
      expect(s.totalPlays, 4);
      expect(s.distinctArtists, 2);
      expect(s.distinctTracks, 3);
      expect(s.distinctAlbums, 2);
      expect(s.activeDays, 3);
    });

    test('los tops suman por entidad y cuentan reproducciones', () {
      final s = StatsCalculator.fromRawEntries(muestra(), bucket: StatsBucket.day);

      // La pista 1 sonó dos veces: 180 s + 60 s.
      expect(s.topTracks.first.id, 1);
      expect(s.topTracks.first.ms, 240000);
      expect(s.topTracks.first.plays, 2);

      expect(s.topArtists.first.id, 100);
      expect(s.topArtists.first.ms, 360000);
      expect(s.topArtists.first.plays, 3);

      expect(s.topGenres.first.genre, 'Rock');
      expect(s.topGenres.first.ms, 360000);
    });

    test('la serie se agrupa por el bucket pedido', () {
      final diaria = StatsCalculator.fromRawEntries(muestra(), bucket: StatsBucket.day);
      expect(diaria.series, hasLength(3));
      expect(diaria.series.first.ms, 300000);

      final semanal = StatsCalculator.fromRawEntries(muestra(), bucket: StatsBucket.week);
      expect(semanal.series, hasLength(1));
      expect(semanal.series.first.ms, 600000);
    });

    test('ignora ids en cero pero suma su tiempo al total', () {
      final s = StatsCalculator.fromRawEntries([
        e(trackId: 0, artistId: 0, albumId: 0, ms: 60000, at: DateTime.utc(2026, 9, 18)),
      ], bucket: StatsBucket.day);

      expect(s.totalMs, 60000);
      expect(s.topArtists, isEmpty);
      expect(s.topTracks, isEmpty);
    });

    test('una lista vacia da un snapshot vacio', () {
      final s = StatsCalculator.fromRawEntries([], bucket: StatsBucket.day);
      expect(s.isEmpty, isTrue);
      expect(s.series, isEmpty);
    });
  });

  group('paridad con el RPC de Postgres', () {
    // Respuesta literal de `get_listening_stats` contra el proyecto real,
    // con p_bucket='day' y p_tz_offset_minutes=0, sobre las mismas 4 filas.
    const jsonDelRpc = '''
{"hours": [{"ms": 240000, "dow": 0, "hour": 10}, {"ms": 60000, "dow": 6, "hour": 15},
 {"ms": 120000, "dow": 5, "hour": 16}, {"ms": 180000, "dow": 5, "hour": 15}],
 "series": [{"t": "2026-09-18T00:00:00+00:00", "ms": 300000, "plays": 2},
            {"t": "2026-09-19T00:00:00+00:00", "ms": 60000, "plays": 1},
            {"t": "2026-09-20T00:00:00+00:00", "ms": 240000, "plays": 1}],
 "total_ms": 600000,
 "top_albums": [{"id": 900, "ms": 360000, "plays": 3}, {"id": 901, "ms": 240000, "plays": 1}],
 "top_genres": [{"ms": 360000, "genre": "Rock", "plays": 3}, {"ms": 240000, "genre": "Pop", "plays": 1}],
 "top_tracks": [{"id": 1, "ms": 240000, "plays": 2}, {"id": 3, "ms": 240000, "plays": 1},
                {"id": 2, "ms": 120000, "plays": 1}],
 "active_days": 3,
 "top_artists": [{"id": 100, "ms": 360000, "plays": 3}, {"id": 200, "ms": 240000, "plays": 1}],
 "total_plays": 4, "distinct_albums": 2, "distinct_tracks": 3, "distinct_artists": 2}
''';

    late StatsSnapshot delServidor;
    late StatsSnapshot deDart;

    setUp(() {
      delServidor = SupabaseStatsRepository.parseSnapshot(
        jsonDecode(jsonDelRpc) as Map<String, dynamic>,
      );
      deDart = StatsCalculator.fromRawEntries(muestra(), bucket: StatsBucket.day);
    });

    test('los totales coinciden', () {
      expect(deDart.totalMs, delServidor.totalMs);
      expect(deDart.totalPlays, delServidor.totalPlays);
      expect(deDart.distinctArtists, delServidor.distinctArtists);
      expect(deDart.distinctTracks, delServidor.distinctTracks);
      expect(deDart.distinctAlbums, delServidor.distinctAlbums);
      expect(deDart.activeDays, delServidor.activeDays);
    });

    test('los tops coinciden', () {
      expect(deDart.topArtists, delServidor.topArtists);
      expect(deDart.topAlbums, delServidor.topAlbums);
      expect(deDart.topGenres, delServidor.topGenres);
      // En canciones hay empate a 240000 ms entre la 1 y la 3; el orden
      // dentro del empate no está definido en ninguno de los dos lados, así
      // que se compara como conjunto.
      expect(deDart.topTracks.toSet(), delServidor.topTracks.toSet());
    });

    test('la serie coincide punto por punto', () {
      // Se comparan FECHAS DE CALENDARIO, no instantes, y a proposito: Dart
      // agrupa por el dia local del dispositivo, mientras que el RPC agrupa
      // por el desfase que se le pasa en `p_tz_offset_minutes` (aqui 0). Los
      // dos dicen "18 de septiembre", pero uno lo representa como medianoche
      // local y el otro como medianoche UTC. En produccion coinciden porque
      // el repositorio le manda al RPC el desfase real del dispositivo.
      String dia(DateTime t) => '${t.year}-${t.month}-${t.day}';

      expect(deDart.series.length, delServidor.series.length);
      for (var i = 0; i < deDart.series.length; i++) {
        expect(dia(deDart.series[i].t), dia(delServidor.series[i].t));
        expect(deDart.series[i].ms, delServidor.series[i].ms);
        expect(deDart.series[i].plays, delServidor.series[i].plays);
      }
    });

    test('el mapa de habitos coincide, con la convencion de dow de Postgres', () {
      int msEn(StatsSnapshot s, int dow, int hour) => s.hours
          .where((h) => h.dow == dow && h.hour == hour)
          .fold<int>(0, (a, h) => a + h.ms);

      for (final cell in delServidor.hours) {
        expect(msEn(deDart, cell.dow, cell.hour), cell.ms,
            reason: 'dow=${cell.dow} hour=${cell.hour}');
      }
    });
  });

  group('rollupMonthlyRows', () {
    MonthlyStatsRow mes(int m, int totalMs, List<StatEntry> artistas) => MonthlyStatsRow(
          monthStart: DateTime(2026, m),
          totalMs: totalMs,
          totalPlays: 10,
          topArtists: artistas,
        );

    test('suma meses y fusiona los tops por id', () {
      final s = StatsCalculator.rollupMonthlyRows([
        mes(7, 100000, [const StatEntry(id: 1, ms: 60000, plays: 3)]),
        mes(8, 200000, [
          const StatEntry(id: 1, ms: 40000, plays: 2),
          const StatEntry(id: 2, ms: 150000, plays: 5),
        ]),
      ]);

      expect(s.totalMs, 300000);
      expect(s.totalPlays, 20);
      expect(s.topArtists.first.id, 2);
      final artista1 = s.topArtists.firstWhere((a) => a.id == 1);
      expect(artista1.ms, 100000);
      expect(artista1.plays, 5);
    });

    test('queda marcado como aproximado', () {
      // Cada mes solo guarda sus 30 mejores, asi que un artista que queda
      // siempre en el puesto 35 no aparece. La pantalla lo advierte.
      final s = StatsCalculator.rollupMonthlyRows([mes(8, 1000, const [])]);
      expect(s.topsAreApproximate, isTrue);
    });

    test('la serie es un punto por mes, ordenada', () {
      final s = StatsCalculator.rollupMonthlyRows([
        mes(9, 300, const []),
        mes(7, 100, const []),
        mes(8, 200, const []),
      ]);
      expect(s.series.map((p) => p.ms), [100, 200, 300]);
    });
  });

  group('periodos', () {
    test('las ventanas cortas usan el historial crudo y las largas el agregado', () {
      expect(StatsPeriod.week.usesMonthlyAggregate, isFalse);
      expect(StatsPeriod.month.usesMonthlyAggregate, isFalse);
      expect(StatsPeriod.quarter.usesMonthlyAggregate, isFalse);
      // Mas alla de 90 dias el crudo ya no existe: se poda.
      expect(StatsPeriod.halfYear.usesMonthlyAggregate, isTrue);
      expect(StatsPeriod.year.usesMonthlyAggregate, isTrue);
      expect(StatsPeriod.allTime.usesMonthlyAggregate, isTrue);
    });

    test('el bucket se adapta para no pasar de ~30 puntos', () {
      expect(StatsPeriod.week.bucket, StatsBucket.day);
      expect(StatsPeriod.month.bucket, StatsBucket.day);
      expect(StatsPeriod.quarter.bucket, StatsBucket.week);
      expect(StatsPeriod.year.bucket, StatsBucket.month);
    });

    test('la ventana de 7 dias es inclusiva: hoy y los seis anteriores', () {
      final hoy = DateTime(2026, 9, 20, 13, 30);
      expect(StatsPeriod.week.startFrom(hoy), DateTime(2026, 9, 14));
    });

    test('"Todo" no tiene inicio', () {
      expect(StatsPeriod.allTime.startFrom(DateTime(2026, 9, 20)), isNull);
    });
  });

  group('formato', () {
    test('se redondea una sola vez, al mostrar', () {
      expect(formatListeningTime(0), '0 min');
      expect(formatListeningTime(5000), '< 1 min');
      expect(formatListeningTime(60000), '1 min');
      expect(formatListeningTime(3600000), '1 h');
      expect(formatListeningTime(3600000 + 120000), '1 h 2 min');
    });
  });
}
