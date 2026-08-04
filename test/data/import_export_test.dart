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
