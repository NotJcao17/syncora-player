import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/library/playlist_permissions.dart';

/// "On Repeat" la mantiene la app y se regenera sola cada semana, así que
/// cualquier cambio manual se perdería sin aviso. Estas dos reglas son las que
/// impiden que eso pase, y están aplicadas en muchos sitios repartidos (el
/// menú de la playlist, el menú de cada pista, el diálogo de "Agregar a
/// playlist", el selector de destino al copiar), así que se testean acá una
/// sola vez.
Playlist playlist({bool isLiked = false, bool isGenerated = false}) => Playlist(
      id: 1,
      title: 'X',
      isPublic: false,
      isLiked: isLiked,
      isPinned: false,
      orderIndex: 0,
      createdAt: DateTime(2026, 9, 21),
      updatedAt: DateTime(2026, 9, 21),
      isGenerated: isGenerated,
    );

void main() {
  group('canEditPlaylistManually', () {
    test('una playlist normal del usuario sí se edita', () {
      expect(canEditPlaylistManually(playlist()), isTrue);
    });

    test('"Tus me gusta" no se edita a mano', () {
      expect(canEditPlaylistManually(playlist(isLiked: true)), isFalse);
    });

    test('una generada tampoco: se regenera sola y el cambio se perdería', () {
      expect(canEditPlaylistManually(playlist(isGenerated: true)), isFalse);
    });
  });

  group('canAddTracksToPlaylist', () {
    test('una playlist normal acepta pistas', () {
      expect(canAddTracksToPlaylist(playlist()), isTrue);
    });

    // Es la diferencia deliberada entre las dos reglas: agregar una canción a
    // "Tus me gusta" es exactamente lo que significa marcarla con me gusta.
    test('"Tus me gusta" SÍ acepta pistas, aunque no se edite', () {
      final liked = playlist(isLiked: true);
      expect(canEditPlaylistManually(liked), isFalse);
      expect(canAddTracksToPlaylist(liked), isTrue);
    });

    test('una generada no acepta pistas por ningún camino', () {
      expect(canAddTracksToPlaylist(playlist(isGenerated: true)), isFalse);
    });
  });
}
