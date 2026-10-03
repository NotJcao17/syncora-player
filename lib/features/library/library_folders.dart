import '../../data/local_db/syncora_database.dart';

/// Elemento de la raíz de la biblioteca (Fase 8.E): una playlist suelta o una
/// carpeta con sus playlists.
sealed class LibraryEntry {
  const LibraryEntry();
}

class PlaylistEntry extends LibraryEntry {
  final Playlist playlist;
  const PlaylistEntry(this.playlist);
}

class FolderEntry extends LibraryEntry {
  final Folder folder;
  final List<Playlist> playlists;
  const FolderEntry(this.folder, this.playlists);
}

/// Arma la raíz de la biblioteca a partir de las playlists **ya ordenadas**
/// (`sortPlaylists`) y las carpetas.
///
/// Orden: playlists fijadas, luego carpetas, luego el resto de playlists. Una
/// playlist dentro de una carpeta solo aparece dentro de ella; si su carpeta
/// ya no existe (borrada en otro dispositivo antes del sync), vuelve a la raíz
/// en vez de desaparecer.
List<LibraryEntry> buildLibraryEntries(List<Playlist> sortedPlaylists, List<Folder> folders) {
  final folderIds = {for (final f in folders) f.id};
  final byFolder = <int, List<Playlist>>{};
  final root = <Playlist>[];
  for (final p in sortedPlaylists) {
    final folderId = p.folderId;
    if (folderId != null && folderIds.contains(folderId)) {
      (byFolder[folderId] ??= []).add(p);
    } else {
      root.add(p);
    }
  }
  return [
    for (final p in root)
      if (p.isPinned) PlaylistEntry(p),
    for (final f in folders) FolderEntry(f, byFolder[f.id] ?? const []),
    for (final p in root)
      if (!p.isPinned) PlaylistEntry(p),
  ];
}

String folderSubtitle(int count) => count == 1 ? 'Carpeta • 1 playlist' : 'Carpeta • $count playlists';
