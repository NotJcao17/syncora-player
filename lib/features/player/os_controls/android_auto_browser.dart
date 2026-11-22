import 'dart:convert';

import 'package:audio_service/audio_service.dart';

import '../../../data/apis/deezer_api.dart';
import '../../../data/local_db/daos/downloaded_track_dao.dart';
import '../../../data/local_db/daos/folder_dao.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/daos/saved_album_dao.dart';
import '../../../data/local_db/playlist_track_mapper.dart';
import '../../../data/local_db/syncora_database.dart';
import '../player_models.dart';

/// Portadas para Android Auto.
///
/// Android Auto solo dibuja portadas de navegación con URIs locales
/// (`content://` o `android.resource://`): con la URL de Deezer tal cual, la
/// cuadrícula salía con cuadros grises. `CoverArtProvider` (paquete
/// `syncora_android`) recibe la URL o la ruta codificada, la descarga una vez a
/// la caché y se la sirve a Android Auto.
abstract final class AutoArt {
  /// `${applicationId}.art`, declarado en el manifiesto de `syncora_android`.
  static const authority = 'com.syncora.syncora_player.art';

  static Uri? of(String? source) {
    if (source == null) return null;
    final s = source.trim();
    if (s.isEmpty) return null;
    final String kind;
    final String value;
    if (s.startsWith('https://') || s.startsWith('http://')) {
      kind = 'img';
      value = s;
    } else if (s.startsWith('file://')) {
      kind = 'file';
      value = Uri.parse(s).toFilePath();
    } else if (s.startsWith('/')) {
      kind = 'file';
      value = s;
    } else {
      return null;
    }
    final encoded = base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    return Uri.parse('content://$authority/$kind/$encoded');
  }

  static Uri? ofUri(Uri? uri) => uri == null ? null : of(uri.toString());
}

/// Lo que hay que poner a sonar al tocar algo en Android Auto.
class AutoPlayRequest {
  const AutoPlayRequest({
    required this.tracks,
    this.startIndex = 0,
    this.shuffle = false,
    this.contextId,
    this.onStarted,
  });

  final List<SyncoraTrack> tracks;
  final int startIndex;

  /// "Reproducir en aleatorio": activa el modo y empieza en una al azar.
  final bool shuffle;
  final String? contextId;

  /// Marca la colección como escuchada (orden de "Escuchado recientemente").
  final Future<void> Function()? onStarted;
}

/// Árbol de navegación de Android Auto (ronda 13, "tipo Spotify").
///
/// Tres pestañas (los hijos navegables de la raíz se dibujan como pestañas):
///
/// - **Inicio**: "Escuchado recientemente" (playlists y álbumes) y "Tu música"
///   (Tus me gusta y las playlists fijadas), en cuadrícula con portada.
/// - **Biblioteca**: Tus me gusta, carpetas, playlists y álbumes guardados.
/// - **Descargas**: las canciones descargadas (funciona sin conexión).
///
/// Dentro de una colección, la primera fila es "Reproducir en aleatorio" y
/// luego sus canciones; tocar una pone la colección entera desde ahí, igual
/// que en la app. Todo sale de Drift salvo las canciones de un álbum guardado,
/// que vienen de Deezer (la base local no las guarda).
class AndroidAutoBrowser {
  AndroidAutoBrowser({
    required this.playlistDao,
    this.savedAlbumDao,
    this.folderDao,
    this.downloadedTrackDao,
    this.deezerApi,
  });

  final PlaylistDao playlistDao;
  final SavedAlbumDao? savedAlbumDao;
  final FolderDao? folderDao;
  final DownloadedTrackDao? downloadedTrackDao;
  final DeezerApi? deezerApi;

  static const home = 'auto:home';
  static const library = 'auto:library';
  static const downloads = 'auto:downloads';
  static const playlistPrefix = 'auto:playlist:';
  static const albumPrefix = 'auto:album:';
  static const folderPrefix = 'auto:folder:';
  static const shuffleSuffix = 'shuffle';

  /// Más filas que esto en una lista se cortan: la respuesta viaja entera por
  /// Binder (tope ~1 MB) y una playlist de miles de canciones la reventaba.
  /// "Reproducir en aleatorio" y tocar cualquier fila usan la lista completa.
  static const maxListedTracks = 400;
  static const recentLimit = 8;

  // Claves de `MediaDescription.extras` que entiende Android Auto.
  static const _browsableHint = 'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
  static const _playableHint = 'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
  static const _groupTitle = 'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';
  static const _downloadStatus = 'android.media.extra.DOWNLOAD_STATUS';
  static const _styleList = 1;
  static const _styleGrid = 2;
  static const _downloaded = 2; // MediaDescriptionCompat.STATUS_DOWNLOADED

  final Map<int, List<SyncoraTrack>> _albumCache = {};

  /// Hijos de [parentId]; lista vacía si no existe o algo falla.
  Future<List<MediaItem>> children(String parentId) async {
    try {
      if (parentId == AudioService.browsableRootId) return _root();
      if (parentId == home) return _home();
      if (parentId == library) return _library();
      if (parentId == downloads) return _downloadsList();
      if (parentId.startsWith(playlistPrefix)) {
        final id = int.tryParse(parentId.substring(playlistPrefix.length));
        return id == null ? const [] : _playlistList(id);
      }
      if (parentId.startsWith(albumPrefix)) {
        final id = int.tryParse(parentId.substring(albumPrefix.length));
        return id == null ? const [] : _albumList(id);
      }
      if (parentId.startsWith(folderPrefix)) {
        final id = int.tryParse(parentId.substring(folderPrefix.length));
        return id == null ? const [] : _folderList(id);
      }
    } catch (_) {}
    return const [];
  }

  /// Qué reproducir para el `mediaId` de una fila tocada
  /// (`<colección>|<índice>` o `<colección>|shuffle`).
  Future<AutoPlayRequest?> resolvePlay(String mediaId) async {
    final sep = mediaId.lastIndexOf('|');
    if (sep < 0) return null;
    final collection = mediaId.substring(0, sep);
    final tail = mediaId.substring(sep + 1);
    final shuffle = tail == shuffleSuffix;
    final index = shuffle ? 0 : (int.tryParse(tail) ?? 0);

    List<SyncoraTrack> tracks;
    String? contextId;
    Future<void> Function()? onStarted;
    if (collection == downloads) {
      tracks = [for (final d in await _downloadedRows()) downloadedTrackToSyncora(d)];
      contextId = 'downloads';
    } else if (collection.startsWith(playlistPrefix)) {
      final id = int.tryParse(collection.substring(playlistPrefix.length));
      if (id == null) return null;
      tracks = await _playlistTracks(id);
      contextId = 'playlist_$id';
      onStarted = () => playlistDao.touchLastPlayed(id);
    } else if (collection.startsWith(albumPrefix)) {
      final id = int.tryParse(collection.substring(albumPrefix.length));
      if (id == null) return null;
      tracks = await _albumTracks(id);
      contextId = 'album_$id';
      final dao = savedAlbumDao;
      if (dao != null) onStarted = () => dao.touchLastPlayed(id);
    } else {
      return null;
    }
    if (tracks.isEmpty) return null;
    return AutoPlayRequest(
      tracks: tracks,
      startIndex: index.clamp(0, tracks.length - 1),
      shuffle: shuffle,
      contextId: contextId,
      onStarted: onStarted,
    );
  }

  /// Filas de canciones de una colección ya resuelta fuera (búsqueda).
  List<MediaItem> trackItems(String collectionId, List<SyncoraTrack> tracks) => [
        for (var i = 0; i < tracks.length && i < maxListedTracks; i++) trackItem('$collectionId|$i', tracks[i]),
      ];

  static MediaItem trackItem(String id, SyncoraTrack t, {Uri? art, bool downloaded = false}) => MediaItem(
        id: id,
        title: t.title,
        artist: t.artist,
        album: t.album ?? '',
        duration: t.duration,
        artUri: art ?? AutoArt.ofUri(t.artUri),
        playable: true,
        extras: downloaded ? const {_downloadStatus: _downloaded} : null,
      );

  // ------------------------------------------------------------------
  // Niveles
  // ------------------------------------------------------------------

  List<MediaItem> _root() => [
        _tab(home, 'Inicio', _styleGrid),
        _tab(library, 'Biblioteca', _styleGrid),
        if (downloadedTrackDao != null) _tab(downloads, 'Descargas', _styleList),
      ];

  MediaItem _tab(String id, String title, int childStyle) => MediaItem(
        id: id,
        title: title,
        playable: false,
        extras: {_browsableHint: childStyle, _playableHint: _styleList},
      );

  Future<List<MediaItem>> _home() async {
    final playlists = await playlistDao.getAllPlaylists();
    final albums = await savedAlbumDao?.getAllSavedAlbums() ?? const <SavedAlbum>[];
    final covers = await _summaryCovers();

    final recent = <({DateTime at, MediaItem item})>[
      for (final p in playlists)
        if (p.lastPlayedAt != null) (at: p.lastPlayedAt!, item: _playlistFolder(p, covers)),
      for (final a in albums)
        if (a.lastPlayedAt != null) (at: a.lastPlayedAt!, item: _albumFolder(a)),
    ]..sort((a, b) => b.at.compareTo(a.at));

    final liked = playlists.where((p) => p.isLiked).firstOrNull;
    final pinned = playlists.where((p) => p.isPinned && !p.isLiked);
    return [
      for (final r in recent.take(recentLimit)) _grouped(r.item, 'Escuchado recientemente'),
      if (liked != null) _grouped(_playlistFolder(liked, covers), 'Tu música'),
      for (final p in pinned) _grouped(_playlistFolder(p, covers), 'Tu música'),
    ];
  }

  Future<List<MediaItem>> _library() async {
    final playlists = await playlistDao.getAllPlaylists();
    final albums = await savedAlbumDao?.getAllSavedAlbums() ?? const <SavedAlbum>[];
    final folders = await folderDao?.getAllFolders() ?? const <Folder>[];
    final covers = await _summaryCovers();
    final folderIds = {for (final f in folders) f.id};

    final liked = playlists.where((p) => p.isLiked).firstOrNull;
    final loose = playlists.where((p) => !p.isLiked && (p.folderId == null || !folderIds.contains(p.folderId)));
    final sortedFolders = [...folders]..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return [
      if (liked != null) _grouped(_playlistFolder(liked, covers), 'Playlists'),
      for (final p in loose) _grouped(_playlistFolder(p, covers), 'Playlists'),
      for (final f in sortedFolders)
        _grouped(
          MediaItem(
            id: '$folderPrefix${f.id}',
            title: f.name,
            displaySubtitle: 'Carpeta',
            playable: false,
            extras: {_browsableHint: _styleGrid},
          ),
          'Carpetas',
        ),
      for (final a in albums) _grouped(_albumFolder(a), 'Álbumes'),
    ];
  }

  Future<List<MediaItem>> _folderList(int folderId) async {
    final playlists = await playlistDao.getAllPlaylists();
    final covers = await _summaryCovers();
    return [
      for (final p in playlists)
        if (p.folderId == folderId && !p.isLiked) _playlistFolder(p, covers),
    ];
  }

  Future<List<MediaItem>> _downloadsList() async {
    final rows = await _downloadedRows();
    if (rows.isEmpty) return const [];
    return [
      _shuffleItem(downloads, rows.length),
      for (var i = 0; i < rows.length && i < maxListedTracks; i++)
        trackItem(
          '$downloads|$i',
          downloadedTrackToSyncora(rows[i]),
          // Sin conexión la URL de Deezer no carga: primero la copia local.
          art: AutoArt.of(rows[i].localCoverPath) ?? AutoArt.of(rows[i].coverUrl),
          downloaded: true,
        ),
    ];
  }

  Future<List<MediaItem>> _playlistList(int playlistId) async {
    final tracks = await _playlistTracks(playlistId);
    final collection = '$playlistPrefix$playlistId';
    if (tracks.isEmpty) return const [];
    return [_shuffleItem(collection, tracks.length), ...trackItems(collection, tracks)];
  }

  Future<List<MediaItem>> _albumList(int albumId) async {
    final tracks = await _albumTracks(albumId);
    final collection = '$albumPrefix$albumId';
    if (tracks.isEmpty) return const [];
    return [_shuffleItem(collection, tracks.length), ...trackItems(collection, tracks)];
  }

  // ------------------------------------------------------------------
  // Piezas
  // ------------------------------------------------------------------

  MediaItem _shuffleItem(String collection, int count) => MediaItem(
        id: '$collection|$shuffleSuffix',
        title: 'Reproducir en aleatorio',
        displaySubtitle: count == 1 ? '1 canción' : '$count canciones',
        playable: true,
      );

  MediaItem _playlistFolder(Playlist p, Map<int, String> covers) {
    final own = p.coverUrl;
    final art = AutoArt.of(own != null && own.isNotEmpty ? own : covers[p.id]);
    return MediaItem(
      id: '$playlistPrefix${p.id}',
      title: p.isLiked ? 'Tus me gusta' : p.title,
      displaySubtitle: 'Playlist',
      artUri: art,
      playable: false,
      extras: {_playableHint: _styleList},
    );
  }

  MediaItem _albumFolder(SavedAlbum a) => MediaItem(
        id: '$albumPrefix${a.albumId}',
        title: a.title,
        displaySubtitle: a.artistName,
        artUri: AutoArt.of(a.coverUrl),
        playable: false,
        extras: {_playableHint: _styleList},
      );

  static MediaItem _grouped(MediaItem item, String group) =>
      item.copyWith(extras: {...?item.extras, _groupTitle: group});

  Future<Map<int, String>> _summaryCovers() async {
    final summaries = await playlistDao.watchPlaylistSummaries().first;
    return {
      for (final e in summaries.entries)
        if (e.value.covers.isNotEmpty) e.key: e.value.covers.first,
    };
  }

  Future<List<SyncoraTrack>> _playlistTracks(int playlistId) async {
    final rows = await playlistDao.getTracksOrdered(playlistId);
    return [for (final r in rows) playlistTrackToSyncora(r)];
  }

  Future<List<DownloadedTrack>> _downloadedRows() async =>
      await downloadedTrackDao?.getAllDownloaded() ?? const <DownloadedTrack>[];

  Future<List<SyncoraTrack>> _albumTracks(int albumId) async {
    final cached = _albumCache[albumId];
    if (cached != null) return cached;
    final api = deezerApi;
    if (api == null) return const [];
    final album = await api.getAlbum(albumId);
    final tracks = [for (final t in album.tracks) t.toSyncoraTrack()];
    _albumCache[albumId] = tracks;
    return tracks;
  }
}
