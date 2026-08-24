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

    test('isAiGenerated defaults to false and can be set / serialized', () {
      const track = SyncoraTrack(
        id: '4',
        title: 'AI Track',
        artist: 'AI Artist',
        isAiGenerated: true,
      );
      expect(track.isAiGenerated, isTrue);

      final json = track.toJson();
      expect(json['isAiGenerated'], isTrue);

      final deserialized = SyncoraTrack.fromJson(json);
      expect(deserialized.isAiGenerated, isTrue);

      final copy = track.copyWith(isAiGenerated: false);
      expect(copy.isAiGenerated, isFalse);
    });
  });

  group('SyncoraArtistRef.encodeList / decodeList round-trip', () {
    test('encodeList returns null for 0 or 1 artists (artistName ya basta)', () {
      expect(SyncoraArtistRef.encodeList(const []), isNull);
      expect(
        SyncoraArtistRef.encodeList(const [SyncoraArtistRef(id: 1, name: 'Solo')]),
        isNull,
      );
    });

    test('encode -> decode preserves id and name for multiple colaboradores', () {
      const original = [
        SyncoraArtistRef(id: 10, name: 'Jesse & Joy'),
        SyncoraArtistRef(id: 20, name: 'Gente De Zona'),
      ];

      final encoded = SyncoraArtistRef.encodeList(original);
      expect(encoded, isNotNull);

      final decoded = SyncoraArtistRef.decodeList(encoded);
      expect(decoded.length, equals(2));
      expect(decoded[0].id, equals(10));
      expect(decoded[0].name, equals('Jesse & Joy'));
      expect(decoded[1].id, equals(20));
      expect(decoded[1].name, equals('Gente De Zona'));
    });

    test('decodeList tolera null, vacío y JSON corrupto sin lanzar', () {
      expect(SyncoraArtistRef.decodeList(null), isEmpty);
      expect(SyncoraArtistRef.decodeList(''), isEmpty);
      expect(SyncoraArtistRef.decodeList('{esto no es json valido'), isEmpty);
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

    test('withContributors reemplaza contributorsList y re-deriva artistName (A5)', () {
      final json = {
        'id': 300,
        'title': '3 A.M.',
        'artist': {'id': 10, 'name': 'Jesse & Joy'},
        'album': {'id': 1, 'title': '3 A.M.'},
        'duration': 183,
      };
      final original = DeezerTrack.fromJson(json);
      expect(original.contributorsList.length, equals(1)); // /search no trae contributors

      final enriched = original.withContributors(const [
        SyncoraArtistRef(id: 10, name: 'Jesse & Joy'),
        SyncoraArtistRef(id: 20, name: 'Gente De Zona'),
      ]);

      expect(enriched.contributorsList.length, equals(2));
      expect(enriched.artistName, equals('Jesse & Joy, Gente De Zona'));
      // El resto de los campos no cambia.
      expect(enriched.id, equals(original.id));
      expect(enriched.title, equals(original.title));
    });

    test('withContributors con lista vacía no modifica el track', () {
      final json = {
        'id': 301,
        'title': 'Solo Track',
        'artist': {'id': 5, 'name': 'Solo Artist'},
        'album': {'id': 1, 'title': 'Album'},
        'duration': 200,
      };
      final original = DeezerTrack.fromJson(json);
      final result = original.withContributors(const []);
      expect(result.artistName, equals(original.artistName));
      expect(result.contributorsList.length, equals(original.contributorsList.length));
    });
  });
}
