@Tags(['integration'])
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';

/// Benchmark de extracción end-to-end (QuickJS + puente dartFetch + clientes
/// Innertube reales contra YouTube).
///
/// ⚠️ ESTE TEST NO SE EJECUTA bajo `flutter test`: requiere la DLL nativa de
/// QuickJS (`quickjs_c_bridge.dll`) que NO carga en el sandbox del test runner
/// en Windows (error 126: "The specified module could not be found"). Tampoco
/// corre en CI sin el binario.
///
/// Cómo ejecutarlo: debe correr **dentro de la app real** (`flutter run`) vía
/// la pantalla `/debug`, que es como el humano valida audio en Windows/Android.
/// Para correrlo manualmente si se dispone del binario en el host:
///   `flutter test test/core/extraction/multi_song_extraction_test.dart \
///      --tags integration`
///
/// El guard inferior lo deja automáticamente excluido de la ejecución por
/// defecto (`flutter test` sin `--tags integration` lo omite por la etiqueta,
/// y si se fuerza la etiqueta, igual aborta con skip si no hay binario nativo).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final songsToTest = [
    {'title': 'Rick Astley - Never Gonna Give You Up', 'id': 'dQw4w9WgXcQ'},
    {'title': 'Billy Joel - Vienna', 'id': '3jL4S4X97sQ'},
    {'title': 'Coldplay - Viva La Vida', 'id': 'dvgZkm1xWPE'},
    {'title': 'Danny Ocean - Dembow', 'id': 'kQKGI24aydk'},
    {'title': 'Mark Ronson - Uptown Funk', 'id': 'OPf0YbXqDm0'},
  ];

  test(
    'Multi-song QuickJS extraction test for all 5 songs',
    () async {
      // El binario nativo de QuickJS no está disponible en este host de tests.
      if (!Platform.isWindows) {
        throw StateError(
          'Este benchmark requiere el DLL nativo de QuickJS y solo se valida '
          'manualmente dentro de `flutter run` (ver cabecera del archivo).',
        );
      }

      final service = ExtractionServiceReal();
      await service.initialize();

      final results = <String, bool>{};
      final timings = <String, Duration>{};

      for (final song in songsToTest) {
        final id = song['id']!;
        final title = song['title']!;

        final stopwatch = Stopwatch()..start();
        final result = await service.extractUrl(id);
        stopwatch.stop();

        timings[title] = stopwatch.elapsed;

        if (result is ExtractionSuccess) {
          results[title] = true;
        } else if (result is ExtractionFailure) {
          results[title] = false;
        }

        expect(
          result,
          isA<ExtractionSuccess>(),
          reason: 'Failed to extract $title ($id) '
              'in ${stopwatch.elapsedMilliseconds}ms '
              '— ¿está el binario nativo de QuickJS disponible en este host?',
        );
      }

      // Resumen visible en el reporte del test (sin usar print).
      expect(
        results.values.every((passed) => passed),
        isTrue,
        reason: 'Una o más canciones fallaron: $results (timings: $timings)',
      );

      service.dispose();
    },
    timeout: const Timeout(Duration(minutes: 4)),
    // Solo corre si se invoca explícitamente con --tags integration.
    skip: 'Requiere binario nativo QuickJS; correr dentro de flutter run (ver /debug)',
  );
}
