// ignore_for_file: prefer_initializing_formals

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local_db/daos/folder_dao.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/supabase/supabase_folder_repository.dart';
import '../../../data/supabase/supabase_playlist_repository.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../auth/local_mode_provider.dart';

/// Toda escritura de carpetas pasa por aquí (Fase 8.E, Pitfall #28): con
/// cuenta, primero Supabase y después Drift; si la nube falla no se toca
/// nada local, porque el siguiente sync lo revertiría. En modo local solo
/// existe Drift.
class FolderService {
  FolderService({
    required FolderDao folderDao,
    required PlaylistDao playlistDao,
    required SupabaseFolderRepository folderRepo,
    required SupabasePlaylistRepository playlistRepo,
    required bool Function() isLocalMode,
  })  : _folderDao = folderDao,
        _playlistDao = playlistDao,
        _folderRepo = folderRepo,
        _playlistRepo = playlistRepo,
        _isLocalMode = isLocalMode;

  final FolderDao _folderDao;
  final PlaylistDao _playlistDao;
  final SupabaseFolderRepository _folderRepo;
  final SupabasePlaylistRepository _playlistRepo;
  final bool Function() _isLocalMode;

  static const int maxNameLength = 100;

  /// Nombre limpio, o `null` si no sirve (vacío).
  static String? cleanName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return null;
    return name.length > maxNameLength ? name.substring(0, maxNameLength) : name;
  }

  /// ¿Esta playlist puede ir dentro de una carpeta? "Tus me gusta" y
  /// "On Repeat" no: las mantiene la app y viven siempre en la raíz. Tampoco
  /// una guardada de otro usuario: la carpeta vive en la fila remota, que es
  /// de su dueño.
  static bool canBeFoldered(Playlist playlist) =>
      !playlist.isLiked && !playlist.isGenerated && !playlist.isFollowed;

  Future<Folder?> folderById(int id) => _folderDao.getFolderById(id);

  /// Crea la carpeta y devuelve su id local, o `null` si no se pudo guardar.
  Future<int?> createFolder(String rawName) async {
    final name = cleanName(rawName);
    if (name == null) return null;
    String? remoteId;
    if (!_isLocalMode()) {
      try {
        remoteId = await _folderRepo.createFolder(name);
      } catch (_) {
        return null;
      }
    }
    return _folderDao.createFolder(name: name, remoteId: remoteId);
  }

  Future<bool> renameFolder(Folder folder, String rawName) async {
    final name = cleanName(rawName);
    if (name == null) return false;
    final remoteId = folder.remoteId;
    if (!_isLocalMode() && remoteId != null) {
      try {
        await _folderRepo.renameFolder(remoteId, name);
      } catch (_) {
        return false;
      }
    }
    await _folderDao.renameFolder(folder.id, name);
    return true;
  }

  /// Borra la carpeta. Sus playlists vuelven a la raíz, nunca se borran.
  Future<bool> deleteFolder(Folder folder) async {
    final remoteId = folder.remoteId;
    if (!_isLocalMode() && remoteId != null) {
      try {
        await _folderRepo.deleteFolder(remoteId);
      } catch (_) {
        return false;
      }
    }
    await _folderDao.deleteFolder(folder.id);
    return true;
  }

  /// Mueve [playlist] a [folder], o a la raíz si [folder] es `null`.
  Future<bool> movePlaylist(Playlist playlist, Folder? folder) async {
    if (!canBeFoldered(playlist)) return false;
    final playlistRemoteId = playlist.remoteId;
    if (!_isLocalMode() && playlistRemoteId != null) {
      // Una carpeta sin id remoto con cuenta es una que todavía no se subió
      // (migración desde modo local a medias): no se puede referenciar.
      if (folder != null && folder.remoteId == null) return false;
      try {
        await _playlistRepo.updatePlaylist(
          playlistRemoteId,
          folderId: folder?.remoteId,
          clearFolder: folder == null,
        );
      } catch (_) {
        return false;
      }
    }
    await _folderDao.setPlaylistFolder(playlist.id, folder?.id);
    return true;
  }

  /// Migración modo local → cuenta (complemento de
  /// `migrateLocalPlaylistsToAccount`, Fase 7.I.10). Se llama **después** de
  /// subir las playlists, porque necesita sus ids remotos.
  ///
  /// Idempotente, igual que la de playlists: solo sube carpetas sin
  /// `remoteId`, y antes de crear una busca otra remota con el mismo nombre
  /// (un reintento tras un fallo a medias no la duplica). Cada paso va en su
  /// propio `try/catch`: un fallo no aborta el resto.
  Future<void> migrateLocalFoldersToAccount() async {
    final pending = (await _folderDao.getAllFolders()).where((f) => f.remoteId == null).toList();
    if (pending.isNotEmpty) {
      List<Map<String, dynamic>> remote = const [];
      try {
        remote = await _folderRepo.fetchUserFolders();
      } catch (_) {}
      for (final folder in pending) {
        try {
          final existing = remote.where((r) => r['name'] == folder.name).firstOrNull;
          final remoteId = existing?['id']?.toString() ?? await _folderRepo.createFolder(folder.name);
          await _folderDao.setRemoteId(folder.id, remoteId);
        } catch (_) {}
      }
    }

    final folders = {for (final f in await _folderDao.getAllFolders()) f.id: f};
    for (final playlist in await _playlistDao.getAllPlaylists()) {
      final folderRemoteId = folders[playlist.folderId]?.remoteId;
      final playlistRemoteId = playlist.remoteId;
      if (folderRemoteId == null || playlistRemoteId == null) continue;
      try {
        await _playlistRepo.updatePlaylist(playlistRemoteId, folderId: folderRemoteId);
      } catch (_) {}
    }
  }
}

final folderServiceProvider = Provider<FolderService>((ref) {
  return FolderService(
    folderDao: ref.watch(folderDaoProvider),
    playlistDao: ref.watch(playlistDaoProvider),
    folderRepo: ref.watch(supabaseFolderRepositoryProvider),
    playlistRepo: ref.watch(supabasePlaylistRepositoryProvider),
    isLocalMode: () => ref.read(localModeProvider),
  );
});

/// Carpetas de la biblioteca, ordenadas.
final foldersProvider = StreamProvider<List<Folder>>((ref) {
  return ref.watch(folderDaoProvider).watchFolders();
});
