import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/widgets/native_cover_spec.dart';
import 'package:syncora_player/data/local_db/daos/playlist_dao.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

void main() {
  late SyncoraDatabase db;
  late PlaylistDao dao;
  setUp(() {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    dao = PlaylistDao(db);
  });
  tearDown(() => db.close());

  Future<Playlist> playlist({String? cover, bool generated = false}) async =>
      (await dao.getPlaylistById(await dao.createPlaylist(title: 'p', coverUrl: cover, isGenerated: generated)))!;

  test('Tus me gusta y On Repeat se dibujan con su degradado y su ícono, no con una canción', () async {
    expect(nativeCoverSpec(await dao.getLikedPlaylist(), fallback: 'https://x.dzcdn.net/a.jpg'),
        'paint:FF6366F1,FF9333EA;heart');
    expect(nativeCoverSpec(await playlist(generated: true), fallback: 'https://x.dzcdn.net/a.jpg'),
        'paint:FF0EA5E9,FF2563EB;repeat');
  });

  test('los degradados y colores de portada se mandan como pintura (no son imágenes)', () async {
    expect(nativeCoverSpec(await playlist(cover: 'gradient:1')), 'paint:FFF59E0B,FFEF4444');
    expect(nativeCoverSpec(await playlist(cover: 'gradient:9')), 'paint:FFF59E0B,FFEF4444', reason: 'el índice da la vuelta');
    expect(nativeCoverSpec(await playlist(cover: 'color:#3B82F6')), 'paint:FF3B82F6');
  });

  test('imágenes propias tal cual; sin portada, la de su primera canción', () async {
    expect(nativeCoverSpec(await playlist(cover: 'https://syncora-images.x.workers.dev/a.jpg')),
        'https://syncora-images.x.workers.dev/a.jpg');
    expect(nativeCoverSpec(await playlist(cover: '/data/user/0/app/cover.jpg')), '/data/user/0/app/cover.jpg');
    expect(nativeCoverSpec(await playlist(), fallback: 'https://x.dzcdn.net/a.jpg'), 'https://x.dzcdn.net/a.jpg');
    expect(nativeCoverSpec(await playlist()), isNull);
  });
}
