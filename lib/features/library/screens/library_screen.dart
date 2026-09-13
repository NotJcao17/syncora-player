import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
import '../../../core/utils/share_link_builder.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/playlist_cover_widget.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../../data/sync/sync_service.dart';
import '../../auth/local_mode_provider.dart';
import '../../download/download_provider.dart';
import '../../player/player_providers.dart';
import '../import_export/playlist_import_export_service.dart';
import '../ai_playlist/ai_create_playlist_sheet.dart';
import '../ai_playlist/ai_modify_playlist_sheet.dart';

/// Pantalla de Biblioteca conectada a Drift local, Supabase y servicio de Import/Export.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _selectedFilter = 'Playlists';
  final List<String> _filters = const ['Playlists', 'Álbumes', 'Descargados'];

  bool _showLocalSearch = false;
  final TextEditingController _localSearchController = TextEditingController();
  String _localSearchQuery = '';

  /// Ronda 3 (D1/D2): criterio de orden y forma de la lista.
  ///
  /// No persisten entre reinicios — el proyecto todavía no tiene
  /// `shared_preferences`, mismo caso (y no una regresión) que
  /// `radioEnabledProvider` o `crossfadeDurationProvider`.
  _LibrarySort _sort = _LibrarySort.recientesEscuchadas;
  bool _gridView = false;

  /// Orden de playlists. Las fijadas van SIEMPRE primero, sea cual sea el
  /// criterio: fijar es una decisión explícita del usuario y no debe poder
  /// perderse por cambiar de orden. Dentro de cada bloque manda [_sort].
  List<Playlist> _sortPlaylists(List<Playlist> input) {
    final list = List<Playlist>.from(input);
    int byPinned(Playlist a, Playlist b) {
      if (a.isPinned == b.isPinned) return 0;
      return a.isPinned ? -1 : 1;
    }

    list.sort((a, b) {
      final pinned = byPinned(a, b);
      if (pinned != 0) return pinned;
      switch (_sort) {
        case _LibrarySort.recientesEscuchadas:
          final aAt = a.lastPlayedAt;
          final bAt = b.lastPlayedAt;
          // Nunca reproducidas al final, y entre ellas por fecha de creación.
          if (aAt == null && bAt == null) return b.createdAt.compareTo(a.createdAt);
          if (aAt == null) return 1;
          if (bAt == null) return -1;
          return bAt.compareTo(aAt);
        case _LibrarySort.recientesAgregadas:
          return b.createdAt.compareTo(a.createdAt);
        case _LibrarySort.alfabetico:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      }
    });
    return list;
  }

  @override
  void initState() {
    super.initState();
    if (!ref.read(localModeProvider)) {
      Future.microtask(() {
        ref.read(syncServiceProvider).syncLibrary(force: false);
        ref.read(syncServiceProvider).syncSavedAlbums(force: false);
      });
    }
  }

  @override
  void dispose() {
    _localSearchController.dispose();
    super.dispose();
  }

  void _showImportDialog(BuildContext context) {
    final isConnected = ref.read(isConnectedProvider).value ?? true;
    if (!isConnected) {
      AppToast.show(context, message: 'Sin conexión. Se requiere internet para importar canciones.');
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(AppIcons.broken(SolarIcons.Import), color: AppTheme.primary, size: 24),
            const SizedBox(width: 10),
            const Text('Importar playlist', style: TextStyle(color: AppTheme.primary, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Importa tus playlists desde Spotify con Exportify:',
                  style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                SizedBox(height: 10),
                Text(
                  '1. Abre tu navegador e ingresa a exportify.net\n'
                  '2. Inicia sesión con tu cuenta de Spotify.\n'
                  '3. Haz clic en "Export" junto a la playlist que deseas para descargar el archivo CSV.\n'
                  '4. Presiona el botón "Seleccionar archivo CSV" aquí abajo para cargar tus canciones en Syncora.',
                  style: TextStyle(color: AppTheme.secondary, fontSize: 13, height: 1.45),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: AppTheme.background,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            icon: Icon(AppIcons.broken(SolarIcons.Upload), size: 18),
            label: const Text('Seleccionar archivo CSV', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () {
              Navigator.pop(ctx);
              _importPlaylistFromFile(context);
            },
          ),
        ],
      ),
    );
  }

  void _showCreatePlaylistDialog(BuildContext context, bool canEdit) {
    if (!canEdit) {
      AppToast.show(context, message: 'Sin conexión. No se pueden crear playlists offline.');
      return;
    }

    final titleController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Nueva Playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              style: const TextStyle(color: AppTheme.primary),
              decoration: const InputDecoration(
                labelText: 'Nombre de la playlist',
                labelStyle: TextStyle(color: AppTheme.secondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.surfaceHover)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.primary)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              style: const TextStyle(color: AppTheme.primary),
              decoration: const InputDecoration(
                labelText: 'Descripción (opcional)',
                labelStyle: TextStyle(color: AppTheme.secondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.surfaceHover)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.primary)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: AppTheme.background,
            ),
            onPressed: () async {
              final title = titleController.text.trim();
              if (title.isNotEmpty) {
                final description = descController.text.trim().isEmpty ? null : descController.text.trim();
                String? remoteId;
                try {
                  final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                  final supabaseRes = await supabaseRepo.createPlaylist(title: title, description: description);
                  remoteId = supabaseRes['id']?.toString();
                } catch (_) {}

                final dao = ref.read(playlistDaoProvider);
                final newPlaylistId = await dao.createPlaylist(
                  title: title,
                  description: description,
                  remoteId: remoteId,
                );
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (context.mounted) context.push('/playlist/$newPlaylistId');
              }
            },
            child: const Text('Crear', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Envuelve una tarjeta/fila de biblioteca con sus gestos de menú
  /// contextual (ronda 3 bis).
  ///
  /// Sustituye al botón de 3 puntitos, que se quitó: en la cuadrícula quedaba
  /// mal encima de la portada, y en la lista competía por el espacio del
  /// título. El menú pasa a abrirse como en el resto de la app — click
  /// derecho en escritorio, mantener pulsado en móvil — que además es donde
  /// el usuario ya lo busca.
  Widget _withContextMenu({
    required Widget child,
    required VoidCallback onTap,
    required VoidCallback? onMenu,
  }) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    return GestureDetector(
      onSecondaryTap: isDesktop ? onMenu : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: isDesktop ? null : onMenu,
        borderRadius: BorderRadius.circular(12),
        child: child,
      ),
    );
  }

  /// Título de una fila/tarjeta de biblioteca, con el indicador de "sonando
  /// ahora" (D3) delante cuando corresponde.
  Widget _libraryTitle(String title, bool isActive, {double fontSize = 16}) {
    return Row(
      children: [
        if (isActive) ...[
          Icon(AppIcons.bold(SolarIcons.SoundwaveSquare),
              color: AppTheme.accent, size: fontSize - 2),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isActive ? AppTheme.accent : AppTheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: fontSize,
            ),
          ),
        ),
      ],
    );
  }

  /// Fila de lista genérica de biblioteca (playlist o álbum).
  Widget _libraryRow({
    required Widget cover,
    required String title,
    required Widget subtitle,
    required bool isActive,
    required VoidCallback onTap,
    VoidCallback? onMenu,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: _withContextMenu(
        onTap: onTap,
        onMenu: onMenu,
        child: Container(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(width: 64, height: 64, child: cover),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _libraryTitle(title, isActive),
                    const SizedBox(height: 4),
                    subtitle,
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }

  /// Celda de cuadrícula genérica de biblioteca (playlist o álbum).
  Widget _libraryGridCell({
    required Widget cover,
    required String title,
    required Widget subtitle,
    required bool isActive,
    required VoidCallback onTap,
    VoidCallback? onMenu,
  }) {
    return _withContextMenu(
      onTap: onTap,
      onMenu: onMenu,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox.expand(child: cover),
            ),
          ),
          const SizedBox(height: 8),
          _libraryTitle(title, isActive, fontSize: 13),
          const SizedBox(height: 2),
          subtitle,
        ],
      ),
    );
  }

  /// Delegado compartido de la cuadrícula: ancho máximo por celda en vez de un
  /// número fijo de columnas, para que se adapte sola del móvil al escritorio.
  SliverGridDelegate _libraryGridDelegate(bool isDesktop) =>
      SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: isDesktop ? 200 : 180,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.78,
      );

  Widget _subtitleText(String text) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
      );

  /// Orden de álbumes guardados, con los mismos tres criterios que las
  /// playlists. Los álbumes no se pueden fijar, así que aquí no hay bloque
  /// de anclados.
  List<SavedAlbum> _sortAlbums(List<SavedAlbum> input) {
    final list = List<SavedAlbum>.from(input);
    list.sort((a, b) {
      switch (_sort) {
        case _LibrarySort.recientesEscuchadas:
          final aAt = a.lastPlayedAt;
          final bAt = b.lastPlayedAt;
          if (aAt == null && bAt == null) return b.addedAt.compareTo(a.addedAt);
          if (aAt == null) return 1;
          if (bAt == null) return -1;
          return bAt.compareTo(aAt);
        case _LibrarySort.recientesAgregadas:
          return b.addedAt.compareTo(a.addedAt);
        case _LibrarySort.alfabetico:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      }
    });
    return list;
  }

  /// Traduce el `activeContextId` del reproductor (`album_42`) al id de álbum.
  static int? _albumIdFromContext(String? activeContextId) {
    if (activeContextId == null) return null;
    if (!activeContextId.startsWith('album_')) return null;
    return int.tryParse(activeContextId.substring('album_'.length));
  }

  /// Traduce el `activeContextId` del reproductor (`playlist_42`) al id de
  /// playlist, o `null` si el contexto activo no es una playlist (búsqueda,
  /// álbum, descargas...).
  static int? _playlistIdFromContext(String? activeContextId) {
    if (activeContextId == null) return null;
    if (!activeContextId.startsWith('playlist_')) return null;
    return int.tryParse(activeContextId.substring('playlist_'.length));
  }

  /// Celda de cuadrícula de una playlist (ronda 3, D2).
  Widget _buildPlaylistGridCell(
    Playlist playlist,
    PlaylistDao playlistDao,
    bool canEdit,
    bool isLocalMode,
    int? activePlaylistId,
  ) {
    return _libraryGridCell(
      cover: PlaylistCoverWidget(
        coverUrl: playlist.coverUrl,
        playlistId: playlist.id,
        isLiked: playlist.isLiked,
      ),
      title: playlist.title,
      isActive: activePlaylistId == playlist.id,
      onTap: () => context.push('/playlist/${playlist.id}'),
      onMenu: playlist.isLiked
          ? null
          : () => _showPlaylistOptionsMenu(context, playlist, canEdit, isLocalMode),
      subtitle: StreamBuilder<List<PlaylistTrack>>(
        stream: playlistDao.watchTracksOrdered(playlist.id),
        builder: (ctx, snap) {
          final count = snap.data?.length ?? 0;
          return _subtitleText(count == 1 ? '1 canción' : '$count canciones');
        },
      ),
    );
  }

  /// Fila de lista de una playlist. [trailingLabel] la usa la sección de
  /// Descargados para añadir "• Descargada" al subtítulo.
  Widget _buildPlaylistRow(
    Playlist playlist,
    PlaylistDao playlistDao,
    bool canEdit,
    bool isLocalMode,
    int? activePlaylistId, {
    String? suffix,
    Widget? trailing,
  }) {
    return _libraryRow(
      cover: PlaylistCoverWidget(
        coverUrl: playlist.coverUrl,
        playlistId: playlist.id,
        isLiked: playlist.isLiked,
      ),
      title: playlist.title,
      isActive: activePlaylistId == playlist.id,
      onTap: () => context.push('/playlist/${playlist.id}'),
      onMenu: playlist.isLiked
          ? null
          : () => _showPlaylistOptionsMenu(context, playlist, canEdit, isLocalMode),
      trailing: trailing,
      subtitle: StreamBuilder<List<PlaylistTrack>>(
        stream: playlistDao.watchTracksOrdered(playlist.id),
        builder: (ctx, snap) {
          final count = snap.data?.length ?? 0;
          final countStr = count == 1 ? '1 canción' : '$count canciones';
          final base = playlist.isLiked ? 'Playlist especial' : countStr;
          return _subtitleText(suffix == null ? base : '$base • $suffix');
        },
      ),
    );
  }

  Widget _buildAlbumCover(SavedAlbum album) => CachedNetworkImage(
        imageUrl: album.coverUrl,
        memCacheWidth: 400,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => Container(
          color: AppTheme.surfaceHover,
          child: Icon(AppIcons.broken(SolarIcons.Vinyl), color: AppTheme.muted, size: 28),
        ),
      );

  Widget _buildAlbumRow(SavedAlbum album, int? activeAlbumId) => _libraryRow(
        cover: _buildAlbumCover(album),
        title: album.title,
        isActive: activeAlbumId == album.albumId,
        onTap: () => context.push('/album/${album.albumId}'),
        onMenu: null,
        subtitle: _subtitleText('Álbum • ${album.artistName}'),
      );

  Widget _buildAlbumGridCell(SavedAlbum album, int? activeAlbumId) => _libraryGridCell(
        cover: _buildAlbumCover(album),
        title: album.title,
        isActive: activeAlbumId == album.albumId,
        onTap: () => context.push('/album/${album.albumId}'),
        onMenu: null,
        subtitle: _subtitleText(album.artistName),
      );

  Widget _buildPlaylistOptionsContent(BuildContext ctx, Playlist playlist, bool canEdit, bool isLocalMode) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(AppIcons.broken(SolarIcons.PenNewSquare), color: canEdit ? AppTheme.primary : AppTheme.muted),
          title: Text('Editar nombre', style: TextStyle(color: canEdit ? AppTheme.primary : AppTheme.muted)),
          enabled: canEdit,
          onTap: () {
            Navigator.pop(ctx);
            _showEditPlaylistDialog(context, playlist);
          },
        ),
        if (!isLocalMode) ...[
          ListTile(
            leading: Icon(
              AppIcons.broken(playlist.isPublic ? SolarIcons.Lock : SolarIcons.Global),
              color: canEdit ? AppTheme.primary : AppTheme.muted,
            ),
            title: Text(
              playlist.isPublic ? 'Hacer privada' : 'Hacer pública',
              style: TextStyle(color: canEdit ? AppTheme.primary : AppTheme.muted),
            ),
            enabled: canEdit,
            onTap: () async {
              Navigator.pop(ctx);
              final newPublic = !playlist.isPublic;
              final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
              final dao = ref.read(playlistDaoProvider);
              String? remoteId = playlist.remoteId;
              if (remoteId == null) {
                try {
                  final supabaseRes = await supabaseRepo.createPlaylist(
                    title: playlist.title,
                    description: playlist.description,
                    isPublic: newPublic,
                    isLiked: playlist.isLiked,
                  );
                  remoteId = supabaseRes['id']?.toString();
                } catch (_) {}
              } else {
                try {
                  await supabaseRepo.updatePlaylist(remoteId, isPublic: newPublic);
                } catch (_) {}
              }
              await dao.updatePlaylist(playlist.copyWith(
                isPublic: newPublic,
                remoteId: Value(remoteId),
              ));
              if (mounted) {
                AppToast.show(
                  context,
                  message: newPublic ? 'Playlist marcada como pública' : 'Playlist marcada como privada',
                );
              }
            },
          ),
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.LinkMinimalistic), color: AppTheme.primary),
            title: const Text('Copiar enlace', style: TextStyle(color: AppTheme.primary)),
            onTap: () {
              Navigator.pop(ctx);
              Clipboard.setData(ClipboardData(text: ShareLinkBuilder.playlist('${playlist.remoteId ?? playlist.id}')));
              AppToast.show(context, message: 'Enlace copiado al portapapeles');
            },
          ),
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.StarsMinimalistic), color: canEdit ? AppTheme.primary : AppTheme.muted),
            title: Text('Modificar con IA', style: TextStyle(color: canEdit ? AppTheme.primary : AppTheme.muted)),
            enabled: canEdit,
            onTap: () {
              Navigator.pop(ctx);
              showAiModifyPlaylistSheet(context, ref, playlist);
            },
          ),
        ],
        ListTile(
          leading: Icon(AppIcons.broken(SolarIcons.TrashBinMinimalistic), color: canEdit ? Colors.redAccent : AppTheme.muted),
          title: Text('Eliminar playlist', style: TextStyle(color: canEdit ? Colors.redAccent : AppTheme.muted)),
          enabled: canEdit,
          onTap: () async {
            Navigator.pop(ctx);
            final confirm = await showDialog<bool>(
              context: context,
              builder: (dCtx) => AlertDialog(
                backgroundColor: AppTheme.surface,
                title: const Text('¿Eliminar playlist?', style: TextStyle(color: AppTheme.primary)),
                content: const Text('Esta acción no se puede deshacer.', style: TextStyle(color: AppTheme.secondary)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancelar')),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => Navigator.pop(dCtx, true),
                    child: const Text('Eliminar'),
                  ),
                ],
              ),
            );

            if (confirm != true) return;

            try {
              final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
              if (playlist.remoteId != null) {
                await supabaseRepo.deletePlaylist(playlist.remoteId!);
              }
            } catch (_) {}
            final dao = ref.read(playlistDaoProvider);
            await dao.deletePlaylist(playlist.id);
            if (mounted) {
              AppToast.show(context, message: 'Playlist eliminada');
            }
          },
        ),
      ],
    );
  }

  void _showPlaylistOptionsMenu(BuildContext context, Playlist playlist, bool canEdit, bool isLocalMode) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    if (isDesktop) {
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: _buildPlaylistOptionsContent(ctx, playlist, canEdit, isLocalMode),
            ),
          ),
        ),
      );
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: AppTheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _buildPlaylistOptionsContent(ctx, playlist, canEdit, isLocalMode),
            ),
          );
        },
      );
    }
  }

  void _showEditPlaylistDialog(BuildContext context, Playlist playlist) {
    final titleController = TextEditingController(text: playlist.title);
    final descController = TextEditingController(text: playlist.description ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Editar Playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              style: const TextStyle(color: AppTheme.primary),
              decoration: const InputDecoration(
                labelText: 'Nombre',
                labelStyle: TextStyle(color: AppTheme.secondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.surfaceHover)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.primary)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              style: const TextStyle(color: AppTheme.primary),
              decoration: const InputDecoration(
                labelText: 'Descripción',
                labelStyle: TextStyle(color: AppTheme.secondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.surfaceHover)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.primary)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: AppTheme.background,
            ),
            onPressed: () async {
              final title = titleController.text.trim();
              if (title.isNotEmpty) {
                final description = descController.text.trim().isEmpty ? null : descController.text.trim();
                final dao = ref.read(playlistDaoProvider);
                await dao.updatePlaylist(playlist.copyWith(
                  title: title,
                  description: Value(description),
                ));

                if (playlist.remoteId != null) {
                  try {
                    final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                    await supabaseRepo.updatePlaylist(
                      playlist.remoteId!,
                      title: title,
                      description: description,
                    );
                  } catch (_) {}
                }

                if (ctx.mounted) Navigator.of(ctx).pop();
                if (context.mounted) {
                  AppToast.show(context, message: 'Playlist actualizada');
                }
              }
            },
            child: const Text('Guardar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _importPlaylistFromFile(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    String content = '';

    if (file.bytes != null) {
      content = String.fromCharCodes(file.bytes!);
    } else if (file.path != null) {
      content = await File(file.path!).readAsString();
    }

    if (content.isEmpty) return;

    final deezerApi = ref.read(deezerApiProvider);
    final service = PlaylistImportExportService(deezerApi);
    final rawTracks = service.parseFileContent(content);

    if (rawTracks.isEmpty) {
      if (context.mounted) {
        AppToast.show(context, message: 'No se encontraron canciones válidas en el archivo.');
      }
      return;
    }

    final dao = ref.read(playlistDaoProvider);
    final playlistTitle = 'Importada: ${file.name.replaceAll(RegExp(r'\.(csv|txt)$'), '')}';
    final playlistDescription = 'Importada desde ${file.name}';

    if (!context.mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        final matched = <dynamic>[];
        final unmatched = <RawImportTrack>[];

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return StreamBuilder<ImportProgress>(
              stream: service.processImport(
                rawTracks: rawTracks,
                outMatched: matched.cast(),
                outUnmatched: unmatched,
              ),
              builder: (ctx, snapshot) {
                final progress = snapshot.data;
                final isDone = snapshot.connectionState == ConnectionState.done;

                if (isDone) {
                  Future.microtask(() {
                    return service.createPlaylistWithMatchedTracks(
                      title: playlistTitle,
                      description: playlistDescription,
                      matchedTracks: matched.cast<DeezerTrack>(),
                      dao: dao,
                      deezerApi: deezerApi,
                      supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
                    );
                  });
                }

                return AlertDialog(
                  backgroundColor: AppTheme.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: Text(
                    isDone ? 'Importación Completada' : 'Importando canciones...',
                    style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isDone) ...[
                        LinearProgressIndicator(
                          value: progress?.ratio ?? 0,
                          backgroundColor: AppTheme.surfaceHover,
                          color: AppTheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Buscando pista ${progress?.current ?? 0} de ${progress?.total ?? rawTracks.length}...',
                          style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          progress?.currentTrackName ?? '',
                          style: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ] else ...[
                        Icon(AppIcons.broken(SolarIcons.CheckCircle), color: Colors.green, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          '${matched.length} encontradas, ${unmatched.length} no encontradas',
                          style: const TextStyle(color: AppTheme.primary, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        if (unmatched.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Canciones no encontradas:',
                              style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(height: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 200),
                            child: SizedBox(
                              width: double.maxFinite,
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: unmatched.length,
                                itemBuilder: (_, i) => Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 3),
                                  child: Text(
                                    unmatched[i].toString(),
                                    style: const TextStyle(color: AppTheme.primary, fontSize: 12),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                  actions: [
                    if (isDone)
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: AppTheme.background,
                        ),
                        onPressed: () => Navigator.of(dialogCtx).pop(),
                        child: const Text('Aceptar', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final playlistDao = ref.watch(playlistDaoProvider);
    final savedAlbumDao = ref.watch(savedAlbumDaoProvider);
    final isConnected = ref.watch(isConnectedProvider).value ?? true;
    final isLocalMode = ref.watch(localModeProvider);
    final canEdit = ref.watch(canEditProvider);

    // Ronda 3 (D3): id de la playlist que está sonando, si el contexto activo
    // del reproductor es una. Sale de `activeContextId`, que ya se guarda con
    // el formato `playlist_<id>` — sin peticiones ni streams nuevos.
    final activeContextId = ref.watch(playerStateProvider.select((s) => s.activeContextId));
    final activePlaylistId = _playlistIdFromContext(activeContextId);
    final activeAlbumId = _albumIdFromContext(activeContextId);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              isDesktop ? 32 : 20,
              isDesktop ? 20 : 12,
              isDesktop ? 32 : 20,
              10,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    isDesktop ? 'Tu Biblioteca' : 'Biblioteca',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.primary,
                      letterSpacing: -0.8,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Fila de accesos (Descargas, Importar, Buscar, IA, Crear):
                // antes iba en un `Flexible` hermano del título, así que ambos
                // se repartían el ancho disponible 50/50 -- en pantallas
                // angostas eso empujaba la mitad de los íconos fuera de la
                // vista, "perdidos" detrás de un scroll horizontal sin
                // affordance visible. Sin `Flexible`/`Expanded` acá, la fila
                // toma solo el ancho que sus íconos necesitan; es el título
                // (ahora `Expanded`, con ellipsis) el que cede espacio.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                        if (isDesktop && !isLocalMode)
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            color: AppTheme.primary,
                            onPressed: () async {
                              await ref.read(syncServiceProvider).syncLibrary(force: true);
                              await ref.read(syncServiceProvider).syncSavedAlbums(force: true);
                            },
                            tooltip: 'Sincronizar biblioteca',
                          ),
                        Tooltip(
                          message: 'Pantalla de descargas',
                          child: IconButton(
                            icon: Icon(AppIcons.broken(SolarIcons.DownloadMinimalistic), color: AppTheme.primary, size: 20),
                            onPressed: () => context.push('/downloads'),
                          ),
                        ),
                        Tooltip(
                          // Importar resuelve cada pista del CSV contra Deezer,
                          // así que sin conexión no puede hacer nada útil.
                          message: isConnected ? 'Importar playlist (CSV/TXT)' : 'Sin conexión',
                          child: IconButton(
                            icon: Icon(
                              AppIcons.broken(SolarIcons.Import),
                              color: isConnected ? AppTheme.primary : AppTheme.muted,
                              size: 20,
                            ),
                            onPressed: isConnected ? () => _showImportDialog(context) : null,
                          ),
                        ),
                        Tooltip(
                          message: 'Buscar en tu biblioteca',
                          child: IconButton(
                            icon: Icon(
                              _showLocalSearch ? AppIcons.broken(SolarIcons.CloseCircle) : AppIcons.broken(SolarIcons.Magnifer),
                              color: AppTheme.primary,
                              size: 20,
                            ),
                            onPressed: () {
                              setState(() {
                                _showLocalSearch = !_showLocalSearch;
                                if (!_showLocalSearch) {
                                  _localSearchController.clear();
                                  _localSearchQuery = '';
                                }
                              });
                            },
                          ),
                        ),
                        if (!isLocalMode)
                          Tooltip(
                            message: isConnected ? 'Crear playlist con IA' : 'Sin conexión',
                            child: IconButton(
                              icon: Icon(
                                AppIcons.broken(SolarIcons.StarsMinimalistic),
                                color: isConnected ? AppTheme.primary : AppTheme.muted,
                                size: 20,
                              ),
                              onPressed: isConnected
                                  ? () => showAiCreatePlaylistSheet(context, ref)
                                  : () {
                                      AppToast.show(context, message: 'Sin conexión. Las funciones de IA necesitan internet.');
                                    },
                            ),
                          ),
                        Tooltip(
                          message: canEdit ? 'Crear playlist' : 'Sin conexión',
                          child: IconButton(
                            icon: Icon(
                              AppIcons.broken(SolarIcons.AddCircle),
                              color: canEdit ? AppTheme.primary : AppTheme.muted,
                              size: 22,
                            ),
                            onPressed: () => _showCreatePlaylistDialog(context, canEdit),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Barra de búsqueda local integrada en la Biblioteca
          if (_showLocalSearch)
            Padding(
              padding: EdgeInsets.fromLTRB(
                isDesktop ? 32 : 20,
                0,
                isDesktop ? 32 : 20,
                10,
              ),
              child: TextField(
                controller: _localSearchController,
                autofocus: true,
                style: const TextStyle(color: AppTheme.primary),
                onChanged: (val) {
                  setState(() {
                    _localSearchQuery = val.trim().toLowerCase();
                  });
                },
                decoration: InputDecoration(
                  hintText: 'Buscar en playlists, álbumes o descargas...',
                  hintStyle: TextStyle(color: AppTheme.secondary.withValues(alpha: 0.7)),
                  prefixIcon: Icon(AppIcons.broken(SolarIcons.Magnifer), color: AppTheme.secondary, size: 18),
                  suffixIcon: _localSearchController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary, size: 18),
                          onPressed: () {
                            _localSearchController.clear();
                            setState(() => _localSearchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: AppTheme.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),

          const Divider(color: AppTheme.surface, height: 1),
          const SizedBox(height: 12),

          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20, vertical: 2),
            child: Row(
              children: _filters.map((filter) {
                final isSelected = _selectedFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(filter),
                    selected: isSelected,
                    onSelected: (val) {
                      if (val) setState(() => _selectedFilter = filter);
                    },
                    selectedColor: AppTheme.primary,
                    backgroundColor: AppTheme.surface,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelStyle: TextStyle(
                      color: isSelected ? AppTheme.background : AppTheme.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                    shape: StadiumBorder(
                      side: BorderSide(
                        color: isSelected ? AppTheme.primary : AppTheme.surfaceHover,
                      ),
                    ),
                    showCheckmark: false,
                  ),
                );
              }).toList(),
            ),
          ),

          const SizedBox(height: 8),

          // Ronda 3 (D1/D2): orden y forma de la lista.
          Padding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: PopupMenuButton<_LibrarySort>(
                      initialValue: _sort,
                      color: AppTheme.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      onSelected: (v) => setState(() => _sort = v),
                      itemBuilder: (ctx) => _LibrarySort.values
                          .map((v) => PopupMenuItem<_LibrarySort>(
                                value: v,
                                child: Text(
                                  v.label,
                                  style: TextStyle(
                                    color: v == _sort ? AppTheme.primary : AppTheme.secondary,
                                    fontSize: 13,
                                    fontWeight: v == _sort ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                              ))
                          .toList(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(AppIcons.broken(SolarIcons.SortVertical),
                              color: AppTheme.secondary, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            _sort.label,
                            style: const TextStyle(
                              color: AppTheme.secondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _gridView ? 'Ver como lista' : 'Ver como cuadrícula',
                  onPressed: () => setState(() => _gridView = !_gridView),
                  icon: Icon(
                    _gridView
                        ? AppIcons.broken(SolarIcons.List)
                        : AppIcons.broken(SolarIcons.WidgetN4),
                    color: AppTheme.secondary,
                    size: 18,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                if (isLocalMode) return;
                await ref.read(syncServiceProvider).syncLibrary(force: true);
                await ref.read(syncServiceProvider).syncSavedAlbums(force: true);
              },
              child: _selectedFilter == 'Álbumes'
                  ? StreamBuilder<List<SavedAlbum>>(
                      stream: savedAlbumDao.watchAllSavedAlbums(),
                      builder: (ctx, snapshot) {
                        final allAlbums = snapshot.data ?? [];
                        final albums = _sortAlbums(allAlbums.where((a) {
                          if (_localSearchQuery.isEmpty) return true;
                          return a.title.toLowerCase().contains(_localSearchQuery) ||
                              a.artistName.toLowerCase().contains(_localSearchQuery);
                        }).toList());

                        if (albums.isEmpty) {
                          return SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Container(
                              height: MediaQuery.of(context).size.height * 0.5,
                              alignment: Alignment.center,
                              child: Text(
                                _localSearchQuery.isNotEmpty ? 'No se encontraron álbumes que coincidan' : 'No tienes álbumes guardados',
                                style: const TextStyle(color: AppTheme.secondary),
                              ),
                            ),
                          );
                        }

                        if (_gridView) {
                          return GridView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                            gridDelegate: _libraryGridDelegate(isDesktop),
                            itemCount: albums.length,
                            itemBuilder: (ctx, i) => _buildAlbumGridCell(albums[i], activeAlbumId),
                          );
                        }

                        return ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                          itemCount: albums.length,
                          itemBuilder: (ctx, i) => _buildAlbumRow(albums[i], activeAlbumId),
                        );
                      },
                    )
                  : _selectedFilter == 'Descargados'
                      ? StreamBuilder<List<DownloadedTrack>>(
                          stream: ref.watch(watchAllDownloadedTracksProvider).when(
                                data: (data) => Stream.value(data),
                                loading: () => Stream.value([]),
                                error: (err, stack) => Stream.value([]),
                              ),
                          builder: (ctx, snapshot) {
                            final downloadedTracks = snapshot.data ?? [];
                            if (downloadedTracks.isEmpty) {
                              return SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                child: Container(
                                  height: MediaQuery.of(context).size.height * 0.5,
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        AppIcons.broken(SolarIcons.CloudDownload),
                                        size: 56,
                                        color: AppTheme.secondary,
                                      ),
                                      const SizedBox(height: 16),
                                      const Text(
                                        'Sin descargas',
                                        style: TextStyle(
                                          color: AppTheme.primary,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 18,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'Descarga playlists o álbumes para escucharlos sin internet',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: AppTheme.secondary,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }

                            return StreamBuilder<List<Playlist>>(
                              stream: playlistDao.watchAllPlaylists(),
                              builder: (ctx, plSnapshot) {
                                final allPlaylists = plSnapshot.data ?? [];
                                final downloadedTrackIds = downloadedTracks.map((t) => t.trackId).toSet();

                                return FutureBuilder<List<Playlist>>(
                                  future: () async {
                                    final result = <Playlist>[];
                                    for (final pl in allPlaylists) {
                                      final tracks = await playlistDao.getTracksOrdered(pl.id);
                                      if (tracks.any((t) => downloadedTrackIds.contains(t.trackId))) {
                                        result.add(pl);
                                      }
                                    }
                                    return result;
                                  }(),
                                  builder: (ctx, filteredSnapshot) {
                                    final allFilteredPlaylists = filteredSnapshot.data ?? [];
                                    final filteredPlaylists = allFilteredPlaylists.where((p) {
                                      if (_localSearchQuery.isEmpty) return true;
                                      return p.title.toLowerCase().contains(_localSearchQuery) ||
                                          (p.description != null && p.description!.toLowerCase().contains(_localSearchQuery));
                                    }).toList();

                                    if (filteredPlaylists.isEmpty) {
                                      return SingleChildScrollView(
                                        physics: const AlwaysScrollableScrollPhysics(),
                                        child: Container(
                                          height: MediaQuery.of(context).size.height * 0.5,
                                          alignment: Alignment.center,
                                          padding: const EdgeInsets.all(24),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                AppIcons.broken(SolarIcons.CloudDownload),
                                                size: 56,
                                                color: AppTheme.secondary,
                                              ),
                                              const SizedBox(height: 16),
                                              Text(
                                                _localSearchQuery.isNotEmpty ? 'No se encontraron descargas que coincidan' : 'Sin descargas',
                                                style: const TextStyle(
                                                  color: AppTheme.primary,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 18,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              const Text(
                                                'Descarga playlists o álbumes para escucharlos sin internet',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  color: AppTheme.secondary,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    }

                                    final ordered = _sortPlaylists(filteredPlaylists);
                                    final descargada = Icon(
                                      AppIcons.bold(SolarIcons.DownloadMinimalistic),
                                      color: AppTheme.secondary,
                                      size: 18,
                                    );

                                    if (_gridView) {
                                      return GridView.builder(
                                        physics: const AlwaysScrollableScrollPhysics(),
                                        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                                        gridDelegate: _libraryGridDelegate(isDesktop),
                                        itemCount: ordered.length,
                                        itemBuilder: (ctx, i) => _buildPlaylistGridCell(
                                          ordered[i],
                                          playlistDao,
                                          canEdit,
                                          isLocalMode,
                                          activePlaylistId,
                                        ),
                                      );
                                    }

                                    return ListView.builder(
                                      physics: const AlwaysScrollableScrollPhysics(),
                                      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                                      itemCount: ordered.length,
                                      itemBuilder: (ctx, i) => _buildPlaylistRow(
                                        ordered[i],
                                        playlistDao,
                                        canEdit,
                                        isLocalMode,
                                        activePlaylistId,
                                        suffix: 'Descargada',
                                        trailing: descargada,
                                      ),
                                    );
                                  },
                                );
                              },
                            );
                          },
                        )
                      : StreamBuilder<List<Playlist>>(
                          stream: playlistDao.watchAllPlaylists(),
                          builder: (ctx, snapshot) {
                            final allPlaylists = snapshot.data ?? [];
                            final playlists = _sortPlaylists(allPlaylists.where((p) {
                              if (_localSearchQuery.isEmpty) return true;
                              return p.title.toLowerCase().contains(_localSearchQuery) ||
                                  (p.description != null && p.description!.toLowerCase().contains(_localSearchQuery));
                            }).toList());

                            if (playlists.isEmpty) {
                              return SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                child: Container(
                                  height: MediaQuery.of(context).size.height * 0.5,
                                  alignment: Alignment.center,
                                  child: Text(
                                    _localSearchQuery.isNotEmpty ? 'No se encontraron playlists que coincidan' : 'No tienes playlists',
                                    style: const TextStyle(color: AppTheme.secondary),
                                  ),
                                ),
                              );
                            }

                            if (_gridView) {
                              return GridView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                                gridDelegate: _libraryGridDelegate(isDesktop),
                                itemCount: playlists.length,
                                itemBuilder: (ctx, i) => _buildPlaylistGridCell(
                                  playlists[i],
                                  playlistDao,
                                  canEdit,
                                  isLocalMode,
                                  activePlaylistId,
                                ),
                              );
                            }

                            return ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                              itemCount: playlists.length,
                              itemBuilder: (ctx, i) => _buildPlaylistRow(
                                playlists[i],
                                playlistDao,
                                canEdit,
                                isLocalMode,
                                activePlaylistId,
                              ),
                            );
                          },
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Criterios de orden de la biblioteca (ronda 3, D1).
enum _LibrarySort {
  recientesEscuchadas('Escuchadas recientemente'),
  recientesAgregadas('Agregadas recientemente'),
  alfabetico('Alfabético');

  const _LibrarySort(this.label);
  final String label;
}
