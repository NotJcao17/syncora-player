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
import '../../../data/local_db/syncora_database.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../../data/sync/sync_service.dart';
import '../../auth/local_mode_provider.dart';
import '../../download/download_provider.dart';
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
                          message: 'Importar playlist (CSV/TXT)',
                          child: IconButton(
                            icon: Icon(AppIcons.broken(SolarIcons.Import), color: AppTheme.primary, size: 20),
                            onPressed: () => _showImportDialog(context),
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

          const SizedBox(height: 16),

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
                        final albums = allAlbums.where((a) {
                          if (_localSearchQuery.isEmpty) return true;
                          return a.title.toLowerCase().contains(_localSearchQuery) ||
                              a.artistName.toLowerCase().contains(_localSearchQuery);
                        }).toList();

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

                        return ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                          itemCount: albums.length,
                          itemBuilder: (ctx, i) {
                            final album = albums[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8.0),
                              child: InkWell(
                                onTap: () => context.push('/album/${album.albumId}'),
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: SizedBox(
                                          width: 64,
                                          height: 64,
                                          child: CachedNetworkImage(
                                            imageUrl: album.coverUrl,
                                            memCacheWidth: 300,
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              album.title,
                                              style: const TextStyle(
                                                color: AppTheme.primary,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Álbum • ${album.artistName}',
                                              style: const TextStyle(
                                                color: AppTheme.secondary,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
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

                                    return ListView.builder(
                                      physics: const AlwaysScrollableScrollPhysics(),
                                      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                                      itemCount: filteredPlaylists.length,
                                      itemBuilder: (ctx, i) {
                                        final playlist = filteredPlaylists[i];
                                        final isLiked = playlist.isLiked;

                                        return Padding(
                                          padding: const EdgeInsets.only(bottom: 8.0),
                                          child: InkWell(
                                            onTap: () => context.push('/playlist/${playlist.id}'),
                                            borderRadius: BorderRadius.circular(12),
                                            child: Container(
                                              padding: const EdgeInsets.all(8),
                                              child: Row(
                                                children: [
                                                  PlaylistCoverWidget(
                                                    coverUrl: playlist.coverUrl,
                                                    playlistId: playlist.id,
                                                    isLiked: isLiked,
                                                    width: 64,
                                                    height: 64,
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  const SizedBox(width: 16),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        Text(
                                                          playlist.title,
                                                          style: const TextStyle(
                                                            color: AppTheme.primary,
                                                            fontWeight: FontWeight.bold,
                                                            fontSize: 16,
                                                          ),
                                                        ),
                                                        const SizedBox(height: 4),
                                                        StreamBuilder<List<PlaylistTrack>>(
                                                          stream: playlistDao.watchTracksOrdered(playlist.id),
                                                          builder: (ctx, trackSnap) {
                                                            final count = trackSnap.data?.length ?? 0;
                                                            final countStr = count == 1 ? '1 canción' : '$count canciones';
                                                            return Text(
                                                              isLiked ? 'Playlist especial • Descargada' : '$countStr • Descargada',
                                                              style: const TextStyle(
                                                                color: AppTheme.secondary,
                                                                fontSize: 13,
                                                              ),
                                                            );
                                                          },
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  Icon(
                                                    AppIcons.bold(SolarIcons.DownloadMinimalistic),
                                                    color: AppTheme.secondary,
                                                    size: 18,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      },
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
                            final playlists = allPlaylists.where((p) {
                              if (_localSearchQuery.isEmpty) return true;
                              return p.title.toLowerCase().contains(_localSearchQuery) ||
                                  (p.description != null && p.description!.toLowerCase().contains(_localSearchQuery));
                            }).toList();

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

                            return ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                              itemCount: playlists.length,
                              itemBuilder: (ctx, i) {
                                final playlist = playlists[i];
                                final isLiked = playlist.isLiked;

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8.0),
                                  child: InkWell(
                                    onTap: () => context.push('/playlist/${playlist.id}'),
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      child: Row(
                                        children: [
                                          PlaylistCoverWidget(
                                            coverUrl: playlist.coverUrl,
                                            playlistId: playlist.id,
                                            isLiked: isLiked,
                                            width: 64,
                                            height: 64,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  playlist.title,
                                                  style: const TextStyle(
                                                    color: AppTheme.primary,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 16,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                StreamBuilder<List<PlaylistTrack>>(
                                                  stream: playlistDao.watchTracksOrdered(playlist.id),
                                                  builder: (ctx, trackSnap) {
                                                    final count = trackSnap.data?.length ?? 0;
                                                    final countStr = count == 1 ? '1 canción' : '$count canciones';
                                                    return Text(
                                                      isLiked ? 'Playlist especial • $countStr' : countStr,
                                                      style: const TextStyle(
                                                        color: AppTheme.secondary,
                                                        fontSize: 13,
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (!isLiked)
                                            IconButton(
                                              icon: Icon(AppIcons.broken(SolarIcons.MenuDots), color: AppTheme.secondary, size: 20),
                                              onPressed: () => _showPlaylistOptionsMenu(context, playlist, canEdit, isLocalMode),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
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
