import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/library/import_export/playlist_import_export_service.dart';

void main() {
  group('PlaylistImportExportService.extractAddCount', () {
    test('reconoce la forma "+N"', () {
      expect(PlaylistImportExportService.extractAddCount('+5'), 5);
      expect(PlaylistImportExportService.extractAddCount('  +12 '), 12);
    });

    test('reconoce verbos con acento y sufijo pegado', () {
      // El caso que fallaba: "agrégame"/"añádeme" no coincidian con la forma
      // exacta del verbo, la peticion caia a regenerar y el progreso mostraba
      // el tamano completo de la playlist.
      expect(PlaylistImportExportService.extractAddCount('agrégame 5 nuevas'), 5);
      expect(PlaylistImportExportService.extractAddCount('añádeme 3 canciones'), 3);
      expect(PlaylistImportExportService.extractAddCount('agregar 7 temas'), 7);
      expect(PlaylistImportExportService.extractAddCount('ponme 4 de rock'), 4);
    });

    test('reconoce cantidad calificada sin verbo', () {
      expect(PlaylistImportExportService.extractAddCount('5 más'), 5);
      expect(PlaylistImportExportService.extractAddCount('10 canciones mas'), 10);
      expect(PlaylistImportExportService.extractAddCount('2 adicionales'), 2);
      expect(PlaylistImportExportService.extractAddCount('6 nuevas'), 6);
    });

    test('devuelve null cuando no se pide agregar nada', () {
      expect(PlaylistImportExportService.extractAddCount('hazla mas alegre'), isNull);
      expect(PlaylistImportExportService.extractAddCount('quita las lentas'), isNull);
      expect(PlaylistImportExportService.extractAddCount(''), isNull);
    });

    test('no confunde un año u otro número suelto sin intención de agregar', () {
      expect(PlaylistImportExportService.extractAddCount('musica de 1990'), isNull);
    });
  });
}
