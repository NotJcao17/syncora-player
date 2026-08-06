import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';

void main() {
  group('SyncoraTrack & SyncoraArtistRef Tests', () {
    test('artist getter returns single artist string when artists list is empty', () {
      const track = SyncoraTrack(
        id: '1',
        title: 'Single Artist Track',
        artist: 'Solo Artist',
      );
      expect(track.artist, equals('Solo Artist'));
      expect(track.artists, isEmpty);
    });

    test('artist getter joins artist names when artists list is not empty', () {
      const track = SyncoraTrack(
        id: '2',
        title: 'Collab Track',
        artist: 'Fallback Artist',
        artists: [
          SyncoraArtistRef(id: 10, name: 'Artist A'),
          SyncoraArtistRef(id: 20, name: 'Artist B'),
        ],
      );
      expect(track.artist, equals('Artist A, Artist B'));
      expect(track.artists.length, equals(2));
      expect(track.artists[0].id, equals(10));
      expect(track.artists[0].name, equals('Artist A'));
    });

    test('copyWith updates artists correctly', () {
      const track = SyncoraTrack(
        id: '3',
        title: 'Track 3',
        artist: 'Initial',
      );
      final updated = track.copyWith(
        artists: const [SyncoraArtistRef(id: 99, name: 'Updated Artist')],
      );
      expect(updated.artist, equals('Updated Artist'));
      expect(updated.artists.first.id, equals(99));
    });
  });

  group('DeezerTrack contributors parsing Tests', () {
    test('parses json contributors into contributorsList', () {
      final json = {
        'id': 100,
        'title': 'Test Song',
        'artist': {'id': 1, 'name': 'Main Artist'},
        'album': {'id': 1, 'title': 'Album'},
        'duration': 180,
        'contributors': [
          {'id': 1, 'name': 'Main Artist'},
          {'id': 2, 'name': 'Featured Artist'},
        ],
      };

      final deezerTrack = DeezerTrack.fromJson(json);
      expect(deezerTrack.contributorsList.length, equals(2));
      expect(deezerTrack.contributorsList[0].name, equals('Main Artist'));
      expect(deezerTrack.contributorsList[1].name, equals('Featured Artist'));
      expect(deezerTrack.artistName, equals('Main Artist, Featured Artist'));

      final syncoraTrack = deezerTrack.toSyncoraTrack();
      expect(syncoraTrack.artists.length, equals(2));
      expect(syncoraTrack.artist, equals('Main Artist, Featured Artist'));
    });

    test('creates contributorsList from artistId and artistName when contributors is empty', () {
      final json = {
        'id': 200,
        'title': 'Solo Song',
        'artist': {'id': 50, 'name': 'Single Deezer Artist'},
        'album': {'id': 1, 'title': 'Album'},
        'duration': 200,
      };

      final deezerTrack = DeezerTrack.fromJson(json);
      expect(deezerTrack.contributorsList.length, equals(1));
      expect(deezerTrack.contributorsList.first.id, equals(50));
      expect(deezerTrack.contributorsList.first.name, equals('Single Deezer Artist'));

      final syncoraTrack = deezerTrack.toSyncoraTrack();
      expect(syncoraTrack.artists.length, equals(1));
      expect(syncoraTrack.artist, equals('Single Deezer Artist'));
    });
  });
}
