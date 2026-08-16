import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/features/library/import_export/playlist_import_export_service.dart';

void main() {
  late PlaylistImportExportService service;

  setUp(() {
    service = PlaylistImportExportService(DeezerApi());
  });

  group('PlaylistImportExportService Tests', () {
    test('Parse standard CSV of 5 tracks', () {
      const csvData = '''title,artist,album
Blinding Lights,The Weeknd,After Hours
Viva La Vida,Coldplay,Viva La Vida
Shape of You,Ed Sheeran,Divide
Starboy,The Weeknd,Starboy
Bohemian Rhapsody,Queen,A Night at the Opera''';

      final result = service.parseFileContent(csvData);
      expect(result.length, equals(5));
      expect(result[0].title, equals('Blinding Lights'));
      expect(result[0].artist, equals('The Weeknd'));
      expect(result[1].title, equals('Viva La Vida'));
    });

    test('Parse TuneMyMusic CSV export format with ISRC column', () {
      const tuneMyMusicData = '''Name,Artist,Album,ISRC
Never Gonna Give You Up,Rick Astley,Whenever You Need Somebody,GBARL8700014
Demons,Imagine Dragons,Night Visions,USUM71200424''';

      final result = service.parseFileContent(tuneMyMusicData);
      expect(result.length, equals(2));
      expect(result[0].title, equals('Never Gonna Give You Up'));
      expect(result[0].artist, equals('Rick Astley'));
      expect(result[0].isrc, equals('GBARL8700014'));
    });

    test('Parse plain text format "Artist - Title"', () {
      const plainText = '''Coldplay - Yellow
Daft Punk - One More Time
Kavinsky - Nightcall''';

      final result = service.parseFileContent(plainText);
      expect(result.length, equals(3));
      expect(result[0].artist, equals('Coldplay'));
      expect(result[0].title, equals('Yellow'));
      expect(result[1].artist, equals('Daft Punk'));
      expect(result[1].title, equals('One More Time'));
    });

    test('B1: reconoce "Artist Name(s)" (formato real de Spotify)', () {
      const spotifyStyle = '''Track Name,Album Name,Artist Name(s),Duration (ms)
Conqueror,All My Demons Greeting Me As A Friend (Deluxe),AURORA,207506''';

      final result = service.parseFileContent(spotifyStyle);
      expect(result.length, equals(1));
      expect(result[0].title, equals('Conqueror'));
      // Antes de B1 esta columna no se reconocía y el artista quedaba vacío
      // en toda la fila — es el bug que causaba ~1/3 de fallos de importación.
      expect(result[0].artist, equals('AURORA'));
      expect(result[0].album, equals('All My Demons Greeting Me As A Friend (Deluxe)'));
      expect(result[0].durationMs, equals(207506));
    });

    test('B4: colaboradores separados por ";" se conservan completos', () {
      const csvData = '''Track Name,Artist Name(s)
La Gozadera (feat. Marc Anthony),Gente De Zona;Marc Anthony''';

      final result = service.parseFileContent(csvData);
      expect(result[0].artist, equals('Gente De Zona;Marc Anthony'));
      // El título original (con el feat) se conserva tal cual para el reporte;
      // la limpieza para la query avanzada (B5) es interna a processImport.
      expect(result[0].title, equals('La Gozadera (feat. Marc Anthony)'));
    });

    test('Fixture real docs/test.csv: 10 filas, todas con artista detectado', () {
      final content = File('docs/test.csv').readAsStringSync();
      final result = service.parseFileContent(content);

      expect(result.length, equals(10));
      expect(result.every((t) => t.artist.isNotEmpty), isTrue);

      final conqueror = result.firstWhere((t) => t.title == 'Conqueror');
      expect(conqueror.artist, equals('AURORA'));
      expect(conqueror.durationMs, equals(207506));

      final gossip = result.firstWhere((t) => t.title.startsWith('GOSSIP'));
      expect(gossip.artist, equals('Måneskin;Tom Morello'));
    });

    test('Export to CSV string format', () {
      final tracks = [
        {
          'title': 'Test Song',
          'artist': 'Test Artist',
          'album': 'Test Album',
          'duration_ms': 180000,
        }
      ];

      final csvStr = service.exportToCsv(tracks);
      expect(csvStr.contains('title,artist,album,duration_ms'), isTrue);
      expect(csvStr.contains('Test Song,Test Artist,Test Album,180000'), isTrue);
    });
  });
}
