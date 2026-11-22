import 'dart:async';

import 'package:syncora_android/syncora_android.dart';

import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/daos/saved_album_dao.dart';
import '../../../data/local_db/syncora_database.dart';
import '../player_models.dart';

/// Lo que muestra el widget "Reproduciendo" (ronda 13).
class NowPlayingWidgetState {
  const NowPlayingWidgetState({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.art,
    required this.playing,
  });

  static const empty = NowPlayingWidgetState(trackId: null, title: '', artist: '', art: null, playing: false);

  factory NowPlayingWidgetState.of(SyncoraTrack? track, {required bool playing}) => track == null
      ? empty
      : NowPlayingWidgetState(
          trackId: track.id,
          title: track.title,
          artist: track.artist,
          art: track.artUri,
          playing: playing,
        );

  final String? trackId;
  final String title;
  final String artist;
  final Uri? art;
  final bool playing;

  bool get hasTrack => trackId != null;

  @override
  bool operator ==(Object other) =>
      other is NowPlayingWidgetState &&
      other.trackId == trackId &&
      other.title == title &&
      other.artist == artist &&
      other.art == art &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(trackId, title, artist, art, playing);
}

typedef NowPlayingSender = Future<void> Function(NowPlayingWidgetState state, String? coverPath);

/// Publica al widget "Reproduciendo" **solo cuando algo cambia** (pista o
/// play/pausa). El controlador notifica ~4 veces por segundo mientras suena
/// (la posición); repintar el widget a ese ritmo gastaría batería, la misma
/// regla de la ronda 10 para lo que se publica al SO.
class NowPlayingWidgetPublisher {
  NowPlayingWidgetPublisher({required this.send, required this.resolveCover});

  final NowPlayingSender send;

  /// Archivo local de la portada (el widget nativo no descarga nada).
  final Future<String?> Function(Uri art) resolveCover;

  NowPlayingWidgetState? _last;
  Uri? _coverFor;
  String? _coverPath;

  void onState(NowPlayingWidgetState state) {
    if (state == _last) return;
    _last = state;
    unawaited(_publish(state));
  }

  Future<void> _publish(NowPlayingWidgetState state) async {
    final art = state.art;
    if (art != _coverFor) {
      String? path;
      if (art != null) {
        try {
          path = await resolveCover(art);
        } catch (_) {
          path = null;
        }
      }
      // Mientras se resolvía pudo cambiar de pista: lo viejo no se publica.
      if (!identical(state, _last)) return;
      _coverFor = art;
      _coverPath = path;
    }
    try {
      await send(state, _coverPath);
    } catch (_) {}
  }
}

/// Entrada del widget de colección para una playlist.
WidgetCollection widgetCollectionForPlaylist(Playlist p, {String? fallbackCover}) {
  final own = p.coverUrl;
  return WidgetCollection(
    kind: 'playlist',
    id: '${p.id}',
    title: p.isLiked ? 'Tus me gusta' : p.title,
    subtitle: 'Playlist',
    cover: own != null && own.isNotEmpty ? own : fallbackCover,
  );
}

WidgetCollection widgetCollectionForAlbum(SavedAlbum a) => WidgetCollection(
      kind: 'album',
      id: '${a.albumId}',
      title: a.title,
      subtitle: a.artistName,
      cover: a.coverUrl.isEmpty ? null : a.coverUrl,
    );

/// Lo que ofrece la pantalla "¿Qué abre este widget?": Tus me gusta, las
/// playlists en el orden de Biblioteca y los álbumes guardados.
List<WidgetCollection> buildWidgetCollections(
  List<Playlist> playlists,
  Map<int, PlaylistSummary> summaries,
  List<SavedAlbum> albums,
) {
  String? firstCover(Playlist p) {
    final covers = summaries[p.id]?.covers;
    return covers == null || covers.isEmpty ? null : covers.first;
  }

  final liked = playlists.where((p) => p.isLiked);
  final rest = playlists.where((p) => !p.isLiked);
  return [
    for (final p in [...liked, ...rest]) widgetCollectionForPlaylist(p, fallbackCover: firstCover(p)),
    for (final a in albums) widgetCollectionForAlbum(a),
  ];
}

/// Mantiene al día la lista de la pantalla de elegir (y el nombre y la
/// portada de los widgets ya puestos) mientras la app está abierta.
class LibraryWidgetPublisher {
  LibraryWidgetPublisher({
    required this.playlistDao,
    required this.savedAlbumDao,
    Future<void> Function(List<WidgetCollection>)? send,
    this.debounce = const Duration(seconds: 2),
  }) : _send = send ?? SyncoraAndroid.publishLibrary;

  final PlaylistDao playlistDao;
  final SavedAlbumDao savedAlbumDao;
  final Duration debounce;
  final Future<void> Function(List<WidgetCollection>) _send;

  final _subs = <StreamSubscription<Object?>>[];
  Timer? _timer;
  List<Playlist>? _playlists;
  Map<int, PlaylistSummary>? _summaries;
  List<SavedAlbum>? _albums;
  List<WidgetCollection>? _lastSent;

  void start() {
    _subs
      ..add(playlistDao.watchAllPlaylists().listen((v) => _update(() => _playlists = v)))
      ..add(playlistDao.watchPlaylistSummaries().listen((v) => _update(() => _summaries = v)))
      ..add(savedAlbumDao.watchAllSavedAlbums().listen((v) => _update(() => _albums = v)));
  }

  void _update(void Function() apply) {
    apply();
    _timer?.cancel();
    _timer = Timer(debounce, _flush);
  }

  void _flush() {
    final playlists = _playlists, summaries = _summaries, albums = _albums;
    if (playlists == null || summaries == null || albums == null) return;
    final items = buildWidgetCollections(playlists, summaries, albums);
    final last = _lastSent;
    if (last != null && last.length == items.length && _sameItems(last, items)) return;
    _lastSent = items;
    unawaited(_send(items).catchError((_) {}));
  }

  static bool _sameItems(List<WidgetCollection> a, List<WidgetCollection> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void dispose() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }
}
