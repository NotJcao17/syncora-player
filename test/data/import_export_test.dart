import 'dart:convert';
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

    test('TuneMyMusic (Amazon): BOM, etiquetas [Explicit]/[Clean] y filas de álbum', () {
      const content = '﻿Track name,Artist name,Album,Playlist name,Type,ISRC,Amazon - id\n'
          '"Payphone [feat. Wiz Khalifa] [Explicit]","Maroon 5","Oldies But Goodies [Explicit]","Library Songs","Favorite","USUM71203347","B08ZQ1F2T4"\n'
          '"Maps","Maroon 5","V (Deluxe) [Clean]","Library Songs","Favorite","USUM71407116","B00XMYEWQY"\n'
          '"The Dark Side of the Moon [Explicit]","Pink Floyd","The Dark Side of the Moon [Explicit]","Library Albums","Album","","B019HKJTCI"';

      final result = service.parseFileContent(content);
      expect(result.length, 2);
      expect(result[0].title, 'Payphone [feat. Wiz Khalifa]');
      expect(result[0].artist, 'Maroon 5');
      expect(result[0].album, 'Oldies But Goodies');
      expect(result[0].isrc, 'USUM71203347');
      expect(result[0].playlistName, 'Library Songs');
      expect(result[1].album, 'V (Deluxe)');
    });

    test('TuneMyMusic con varias playlists: se reparten por "Playlist name"', () {
      const content = '﻿Track name,Artist name,Album,Playlist name,Type,ISRC,Spotify - id\n'
          '"GRAN VÍA","Quevedo","BUENAS NOCHES","test 2","Playlist","ES03H2400005","2kQ1OvmMzs1xdlH020aJJh"\n'
          '"Loser","Tame Impala","Deadbeat","otra","Playlist","USQX92504224","7bxaFZ1O3cHkgLKMsdC3xR"\n'
          '"Primadonna","MARINA","Electra Heart (Deluxe)","test 2","Playlist","GBFFS1200009","4sOX1nhpKwFWPvoMMExi3q"';

      final groups = PlaylistImportExportService.groupByPlaylist(service.parseFileContent(content));
      expect(groups.map((g) => g.name), ['test 2', 'otra']);
      expect(groups.first.tracks.map((t) => t.title), ['GRAN VÍA', 'Primadonna']);
    });

    test('decodeFileBytes: UTF-8 con acentos y respaldo Latin-1', () {
      expect(PlaylistImportExportService.decodeFileBytes(utf8.encode('GRAN VÍA')), 'GRAN VÍA');
      expect(PlaylistImportExportService.decodeFileBytes(latin1.encode('Canción')), 'Canción');
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
