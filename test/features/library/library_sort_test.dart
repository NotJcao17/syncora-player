import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/library/library_view_settings.dart';

Playlist _pl(int id, String title, {bool pinned = false, bool liked = false, DateTime? played, DateTime? created}) {
  return Playlist(
    id: id,
    title: title,
    isPublic: false,
    isLiked: liked,
    isPinned: pinned,
    orderIndex: liked ? -1 : 0,
    createdAt: created ?? DateTime(2026, 1, id),
    updatedAt: DateTime(2026, 1, id),
    lastPlayedAt: played,
    isGenerated: false,
  );
}

void main() {
  test('las fijadas van primero y "Tus me gusta" no tiene trato especial', () {
    final liked = _pl(1, 'Tus me gusta', liked: true);
    final a = _pl(2, 'Alfa');
    final z = _pl(3, 'Zeta', pinned: true);
    final sorted = sortPlaylists([liked, a, z], LibrarySort.alfabetico);
    expect(sorted.map((p) => p.title), ['Zeta', 'Alfa', 'Tus me gusta']);
  });

  test('escuchadas recientemente: las nunca reproducidas al final', () {
    final never = _pl(1, 'Nunca');
    final old = _pl(2, 'Vieja', played: DateTime(2026, 2, 1));
    final recent = _pl(3, 'Reciente', played: DateTime(2026, 3, 1));
    final sorted = sortPlaylists([never, old, recent], LibrarySort.recientesEscuchadas);
    expect(sorted.map((p) => p.title), ['Reciente', 'Vieja', 'Nunca']);
  });
}
