import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/models/deezer/deezer_artist.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/radio/radio_service.dart';

/// Suite de las funciones PURAS de [RadioService] (Fase 7.B.7 del plan).
///
/// Mismo patrón que `search_ranking_test.dart`: fixtures JSON reales
/// capturadas de la API de Deezer (`test/fixtures/deezer_radio/`, agosto
/// 2026), sin mockear Dio/`DeezerApi` en ningún lado — no hay precedente de
/// eso en el proyecto. Solo la orquestación con I/O de
/// [RadioService.generateBatch] queda fuera de esta suite (ver nota al final
/// del archivo).
Map<String, dynamic> _loadFixture(String name) {
  final file = File('test/fixtures/deezer_radio/$name.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<DeezerTrack> _parseTracks(String fixtureName) {
  final fixture = _loadFixture(fixtureName);
  final raw = fixture['data'] as List;
  // Mismo filtro de calidad que deezer_api.dart (duración>60, no podcast).
  return raw
      .where((t) => ((t as Map)['duration'] as int? ?? 0) > 60 && t['type'] != 'podcast')
      .map((t) => DeezerTrack.fromJson(Map<String, dynamic>.from(t as Map)))
      .toList();
}

List<DeezerArtist> _parseArtists(String fixtureName) {
  final fixture = _loadFixture(fixtureName);
  final raw = fixture['data'] as List;
  return raw.map((a) => DeezerArtist.fromJson(Map<String, dynamic>.from(a as Map))).toList();
}

void main() {
  group('RadioService.countArtistFrequency', () {
    test('cuenta apariciones por artistId principal, ignora sin artistId identificable', () {
      final tracks = [
        const SyncoraTrack(id: '1', title: 'A', artistId: 100),
        const SyncoraTrack(id: '2', title: 'B', artistId: 100),
        const SyncoraTrack(id: '3', title: 'C', artistId: 200),
        const SyncoraTrack(id: '4', title: 'D', artistId: null),
        const SyncoraTrack(id: '5', title: 'E', artistId: 0),
      ];

      final freq = RadioService.countArtistFrequency(tracks);

      expect(freq, {100: 2, 200: 1});
    });

    test('lista vacía produce mapa vacío', () {
      expect(RadioService.countArtistFrequency(const []), isEmpty);
    });
  });

  group('RadioService.weightedSampleArtists', () {
    test('nunca devuelve más elementos que artistas distintos disponibles', () {
      final freq = {1: 5, 2: 3, 3: 1};
      final sample = RadioService.weightedSampleArtists(freq, 10, Random(42));
      expect(sample.length, 3);
      expect(sample.toSet().length, 3, reason: 'sin reemplazo: no debe repetir artistas');
    });

    test('respeta el count pedido cuando hay más artistas que count', () {
      final freq = {1: 5, 2: 3, 3: 1, 4: 1, 5: 1, 6: 1};
      final sample = RadioService.weightedSampleArtists(freq, 5, Random(7));
      expect(sample.length, 5);
      expect(sample.toSet().length, 5);
    });

    test('mapa vacío o count 0 no lanza y devuelve vacío', () {
      expect(RadioService.weightedSampleArtists({}, 5, Random(1)), isEmpty);
      expect(RadioService.weightedSampleArtists({1: 1}, 0, Random(1)), isEmpty);
    });

    test('determinista: misma semilla produce el mismo resultado', () {
      final freq = {1: 5, 2: 3, 3: 1, 4: 1, 5: 2};
      final a = RadioService.weightedSampleArtists(freq, 3, Random(123));
      final b = RadioService.weightedSampleArtists(freq, 3, Random(123));
      expect(a, b);
    });

    test('un artista mucho más frecuente sale elegido primero con mucha más probabilidad (test estadístico)',
        () {
      // Distribución muy desbalanceada: artista 1 aparece 97 veces más que
      // el resto combinado. Repetir el muestreo con muchas semillas
      // distintas y contar cuántas veces el artista 1 sale PRIMERO en el
      // resultado — debe ganar la inmensa mayoría de las corridas.
      final freq = {1: 970, 2: 10, 3: 10, 4: 5, 5: 5};
      var firstPickIsDominant = 0;
      const runs = 300;
      for (var seed = 0; seed < runs; seed++) {
        final sample = RadioService.weightedSampleArtists(freq, 1, Random(seed));
        if (sample.isNotEmpty && sample.first == 1) firstPickIsDominant++;
      }
      // Con ~97% de peso relativo, se espera un dominio aplastante; se deja
      // margen generoso (>80%) para no volver el test frágil ante la
      // implementación exacta del muestreo.
      expect(firstPickIsDominant / runs, greaterThan(0.8));
    });

    test('un artista con peso mucho menor sale elegido raras veces, pero no nunca (sigue teniendo peso > 0)', () {
      final freq = {1: 100, 2: 1};
      var artist2Picks = 0;
      const runs = 2000;
      for (var seed = 0; seed < runs; seed++) {
        final sample = RadioService.weightedSampleArtists(freq, 1, Random(seed));
        if (sample.isNotEmpty && sample.first == 2) artist2Picks++;
      }
      final rate = artist2Picks / runs;
      expect(rate, lessThan(0.2), reason: 'con 100x menos peso, debe ganar raras veces');
      expect(artist2Picks, greaterThan(0), reason: 'pero sigue teniendo peso > 0, no debe ser "nunca"');
    });
  });

  group('RadioService.completeSeeds', () {
    test('completa hasta target usando el pool de relacionados, preservando las semillas actuales', () {
      final related = [
        const DeezerArtist(id: 10, name: 'Rel A', pictureUrl: '', nbFan: 1000),
        const DeezerArtist(id: 20, name: 'Rel B', pictureUrl: '', nbFan: 1000),
        const DeezerArtist(id: 30, name: 'Rel C', pictureUrl: '', nbFan: 1000),
      ];

      final seeds = RadioService.completeSeeds(
        currentSeeds: [1],
        relatedPool: related,
        target: 4,
      );

      expect(seeds, [1, 10, 20, 30]);
    });

    test('caso de 1 solo artista: completa con sus propios relacionados', () {
      final adeleRelated = _parseArtists('adele_related');
      final seeds = RadioService.completeSeeds(
        currentSeeds: [75798], // Adele
        relatedPool: adeleRelated,
        target: 5,
      );

      expect(seeds.length, 5);
      expect(seeds.first, 75798);
      expect(seeds.toSet().length, 5, reason: 'no debe haber duplicados');
    });

    test('no duplica un artista ya presente en currentSeeds o en excludeArtistIds', () {
      final related = [
        const DeezerArtist(id: 1, name: 'Ya semilla', pictureUrl: '', nbFan: 1),
        const DeezerArtist(id: 2, name: 'Excluido', pictureUrl: '', nbFan: 1),
        const DeezerArtist(id: 3, name: 'Nuevo', pictureUrl: '', nbFan: 1),
      ];

      final seeds = RadioService.completeSeeds(
        currentSeeds: [1],
        relatedPool: related,
        excludeArtistIds: {2},
        target: 5,
      );

      expect(seeds, [1, 3], reason: 'id 1 ya estaba, id 2 está excluido, solo entra el 3');
    });

    test('si el pool de relacionados no alcanza para llegar a target, devuelve menos sin fallar', () {
      final seeds = RadioService.completeSeeds(
        currentSeeds: [1],
        relatedPool: [const DeezerArtist(id: 2, name: 'Solo uno', pictureUrl: '', nbFan: 1)],
        target: 5,
      );

      expect(seeds, [1, 2]);
    });

    test('currentSeeds ya en target no toca el pool', () {
      final seeds = RadioService.completeSeeds(
        currentSeeds: [1, 2, 3, 4, 5],
        relatedPool: [const DeezerArtist(id: 6, name: 'Extra', pictureUrl: '', nbFan: 1)],
        target: 5,
      );
      expect(seeds, [1, 2, 3, 4, 5]);
    });
  });

  group('RadioService.interleaveRoundRobin', () {
    test('combina listas por artista una por turno, no en bloques (revisión de 7.B, bug #4)', () {
      final a = [
        const DeezerTrack(id: 1, title: 'A1', artistName: 'A', artistId: 1, albumTitle: '', albumId: 0, coverUrl: '', durationSec: 200),
        const DeezerTrack(id: 2, title: 'A2', artistName: 'A', artistId: 1, albumTitle: '', albumId: 0, coverUrl: '', durationSec: 200),
        const DeezerTrack(id: 3, title: 'A3', artistName: 'A', artistId: 1, albumTitle: '', albumId: 0, coverUrl: '', durationSec: 200),
      ];
      final b = [
        const DeezerTrack(id: 10, title: 'B1', artistName: 'B', artistId: 2, albumTitle: '', albumId: 0, coverUrl: '', durationSec: 200),
        const DeezerTrack(id: 20, title: 'B2', artistName: 'B', artistId: 2, albumTitle: '', albumId: 0, coverUrl: '', durationSec: 200),
      ];
      final c = [
        const DeezerTrack(id: 100, title: 'C1', artistName: 'C', artistId: 3, albumTitle: '', albumId: 0, coverUrl: '', durationSec: 200),
      ];

      final result = RadioService.interleaveRoundRobin([a, b, c]);

      expect(result.map((t) => t.id).toList(), [1, 10, 100, 2, 20, 3],
          reason: 'turno 0: A1,B1,C1 -- turno 1: A2,B2 (C agotado) -- turno 2: A3 (B y C agotados)');
    });

    test('listas vacías o el conjunto vacío no lanzan', () {
      expect(RadioService.interleaveRoundRobin([]), isEmpty);
      expect(RadioService.interleaveRoundRobin([[], []]), isEmpty);
    });

    test('con fixtures reales, ninguna semilla individual domina el resultado final tras filterDedupQuota', () {
      // Reproduce el escenario reportado en la revisión: concatenar en
      // bloques dejaba que una sola semilla aportara ~20 de 25 pistas del
      // lote final. Con round-robin, ninguna debería aportar más que su
      // "turno justo" (aprox. targetCount / nº de semillas, con margen).
      final perArtist = [
        _parseTracks('adele_radio').take(5).toList(),
        _parseTracks('ed_sheeran_radio').take(5).toList(),
        _parseTracks('eminem_radio').take(5).toList(),
      ];
      final pool = RadioService.interleaveRoundRobin(perArtist);
      final batch = RadioService.filterDedupQuota(
        candidates: pool,
        excludeIds: const {},
        targetCount: 12,
      );

      final adeleIds = perArtist[0].map((t) => t.id).toSet();
      final fromAdele = batch.where((t) => adeleIds.contains(t.id)).length;
      expect(fromAdele, lessThanOrEqualTo(5),
          reason: 'con solo 5 candidatos de Adele en el pool, como máximo puede aportar 5 igual, '
              'pero no debería agotar los 12 del lote ella sola dejando 0 para las otras dos semillas');
      expect(batch.length, greaterThan(fromAdele),
          reason: 'las otras semillas SÍ deben aparecer en el lote final, no solo la primera');
    });
  });

  group('RadioService.filterDedupQuota', () {
    test('descarta candidatos por debajo del umbral de "popular" (SearchRanking.isPopularTrack)', () {
      final adeleRadio = _parseTracks('adele_radio');
      // Confirma que la fixture real trae variedad de ranks (algunos por
      // debajo del umbral, algunos por encima) para que el test sea real.
      final anyBelow = adeleRadio.any((t) => (t.rank ?? 0) < 300000);
      final anyAbove = adeleRadio.any((t) => (t.rank ?? 0) >= 300000);
      expect(anyBelow, isTrue, reason: 'la fixture debe tener al menos un candidato de rank bajo');
      expect(anyAbove, isTrue, reason: 'la fixture debe tener al menos un candidato de rank alto');

      final result = RadioService.filterDedupQuota(
        candidates: adeleRadio,
        excludeIds: const {},
        targetCount: 100,
      );

      expect(result, isNotEmpty);
      for (final t in result) {
        expect(t.rank, greaterThanOrEqualTo(300000),
            reason: 'ningún track por debajo del umbral de popularidad debe colarse');
      }
      expect(result.length, lessThan(adeleRadio.length),
          reason: 'la fixture real tiene candidatos de rank bajo que deben quedar fuera');
    });

    test('deduplica candidatos repetidos entre distintas fuentes (radio + related de otro artista)', () {
      final adeleRadio = _parseTracks('adele_radio');
      final edSheeranRadio = _parseTracks('ed_sheeran_radio');
      // Elegir a propósito un candidato POPULAR de Adele (si no, el filtro de
      // rank ya lo descartaría y el test no probaría nada sobre dedup) y
      // duplicarlo, simulando que el mismo track aparece en dos pools
      // combinados (ej. /radio de dos artistas semilla distintos).
      final popularAdeleTrack = adeleRadio.firstWhere((t) => (t.rank ?? 0) >= 300000);
      final duplicated = [...adeleRadio, popularAdeleTrack, ...edSheeranRadio];

      final result = RadioService.filterDedupQuota(
        candidates: duplicated,
        excludeIds: const {},
        targetCount: 1000,
      );

      final ids = result.map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'no debe haber ids repetidos en el resultado');
      expect(ids.where((id) => id == popularAdeleTrack.id).length, 1,
          reason: 'el track duplicado a propósito debe aparecer exactamente una vez');
    });

    test('excluye ids presentes en excludeIds (comparados como String)', () {
      final adeleRadio = _parseTracks('adele_radio');
      final popular = adeleRadio.where((t) => (t.rank ?? 0) >= 300000).toList();
      expect(popular, isNotEmpty);
      final excluded = popular.first;

      final result = RadioService.filterDedupQuota(
        candidates: adeleRadio,
        excludeIds: {excluded.id.toString()},
        targetCount: 1000,
      );

      expect(result.any((t) => t.id == excluded.id), isFalse);
    });

    test('recorta al targetCount tomando solo los primeros válidos (soporta pedir con buffer)', () {
      final adeleRadio = _parseTracks('adele_radio');
      final popularCount = adeleRadio.where((t) => (t.rank ?? 0) >= 300000).length;
      expect(popularCount, greaterThan(3), reason: 'la fixture debe tener más de 3 candidatos válidos');

      final result = RadioService.filterDedupQuota(
        candidates: adeleRadio,
        excludeIds: const {},
        targetCount: 3,
      );

      expect(result.length, 3);
    });

    test('no falla si sobran candidatos ni si faltan (menos que targetCount)', () {
      final short = _parseTracks('ed_sheeran_radio').take(2).toList();
      final result = RadioService.filterDedupQuota(
        candidates: short,
        excludeIds: const {},
        targetCount: 25,
      );
      expect(result.length, lessThanOrEqualTo(2));
    });

    test('lista vacía de candidatos no lanza', () {
      expect(
        RadioService.filterDedupQuota(candidates: const [], excludeIds: const {}, targetCount: 25),
        isEmpty,
      );
    });
  });
}

// Nota de cobertura (honestidad pedida en la tarea): RadioService.generateBatch
// (la orquestación con I/O real: countArtistFrequency -> weightedSampleArtists
// -> completeSeeds (con /related real) -> Future.wait de /radio -> pipeline)
// NO tiene test unitario directo en este archivo, incluido el caso de
// "contexto vacío -> fallback a getTopCharts". El proyecto no tiene ningún
// precedente de mockear DeezerApi/Dio (ver deezer_api.dart, sin tests hoy;
// search_ranking_test.dart prueba solo las funciones puras contra fixtures).
// Cada pieza que generateBatch orquesta SÍ está cubierta arriba de forma
// pura; el propio camino de integración de red se deja como camino no
// cubierto por unit test, igual que el resto de DeezerApi. La integración
// con SyncoraPlayerController (disparo condicional, no-toca-manualQueue,
// descarte por cambio de contexto) sí se cubre inyectando un RadioService
// fake en syncora_player_controller_test.dart.
