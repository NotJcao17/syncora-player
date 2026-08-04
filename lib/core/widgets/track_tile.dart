import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../data/local_db/database_provider.dart';
import '../../features/player/player_models.dart';
import '../theme/app_theme.dart';
import 'app_bottom_sheet.dart';

/// Componente de fila de canción reutilizable.
class TrackTile extends ConsumerWidget {
  final SyncoraTrack track;
  final int? index;
  final bool isPlaying;
  final bool isDownloaded;
  final bool isAvailable;
  final VoidCallback? onTap;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onMorePressed;

  const TrackTile({
    super.key,
    required this.track,
    this.index,
    this.isPlaying = false,
    this.isDownloaded = false,
    this.isAvailable = true,
    this.onTap,
    this.onAddToQueue,
    this.onMorePressed,
  });

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textColor = isAvailable
        ? (isPlaying ? AppTheme.primary : AppTheme.primary)
        : AppTheme.muted;
    final subtitleColor = isAvailable ? AppTheme.secondary : AppTheme.muted;
    final showIndexOrIcon = isPlaying || index != null;

    Widget content = InkWell(
      onTap: isAvailable ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: isPlaying ? AppTheme.surfaceHover.withValues(alpha: 0.6) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // Número o Indicador de reproducción (solo si index != null o isPlaying)
              if (showIndexOrIcon) ...[
                SizedBox(
                  width: 28,
                  child: isPlaying
                      ? const Icon(LucideIcons.barChart2, color: AppTheme.primary, size: 18)
                      : Text(
                          '${index! + 1}',
                          style: TextStyle(
                            color: isPlaying ? AppTheme.primary : AppTheme.secondary.withValues(alpha: 0.7),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                ),
                const SizedBox(width: 8),
              ],

              // Portada de 48x48 con memCacheWidth: 300 (Pitfall #9)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: track.coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: track.coverUrl,
                          memCacheWidth: 300,
                          fit: BoxFit.cover,
                          errorWidget: (context, url, error) => _buildPlaceholder(),
                          placeholder: (context, url) => Container(color: AppTheme.surfaceHover),
                        )
                      : _buildPlaceholder(),
                ),
              ),
              const SizedBox(width: 12),

              // Título y Artista
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        if (!isAvailable) ...[
                          const Icon(LucideIcons.triangleAlert, size: 14, color: AppTheme.muted),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 15,
                              fontWeight: isPlaying ? FontWeight.w700 : FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (isDownloaded) ...[
                          const Icon(LucideIcons.arrowDownToLine, size: 12, color: AppTheme.secondary),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: subtitleColor,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Duración
              Text(
                _formatDuration(track.duration ?? Duration.zero),
                style: const TextStyle(
                  color: AppTheme.muted,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 8),

              // Menú de 3 puntos (PopupMenuButton en desktop / bottom sheet en movil)
              _buildMoreButton(context, ref),
            ],
          ),
        ),
      ),
    );

    // Swipe a la derecha -> Agregar a cola
    if (onAddToQueue != null && isAvailable) {
      return Dismissible(
        key: Key('track_dismiss_${track.id}_${index ?? 0}'),
        direction: DismissDirection.startToEnd,
        confirmDismiss: (dir) async {
          onAddToQueue!();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('"${track.title}" agregada a la cola'),
              duration: const Duration(seconds: 2),
            ),
          );
          return false;
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 20),
          decoration: BoxDecoration(
            color: AppTheme.surfaceActive,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            children: [
              Icon(LucideIcons.listPlus, color: AppTheme.primary, size: 20),
              SizedBox(width: 8),
              Text(
                'Agregar a cola',
                style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        child: content,
      );
    }

    return content;
  }

  Widget _buildMoreButton(BuildContext context, WidgetRef ref) {
    if (onMorePressed != null) {
      return IconButton(
        icon: const Icon(LucideIcons.ellipsisVertical, size: 18, color: AppTheme.secondary),
        onPressed: onMorePressed,
        tooltip: 'Opciones',
      );
    }

    final isDesktop = MediaQuery.of(context).size.width >= 768;

    if (isDesktop) {
      return PopupMenuButton<String>(
        icon: const Icon(LucideIcons.ellipsisVertical, size: 18, color: AppTheme.secondary),
        color: const Color(0xFF1E1E1E),
        elevation: 10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF2A2A2A)),
        ),
        onSelected: (value) async {
          _handleOptionSelected(context, ref, value);
        },
        itemBuilder: (ctx) => [
          const PopupMenuItem(
            value: 'playlist',
            child: Row(
              children: [
                Icon(LucideIcons.plus, color: AppTheme.primary, size: 18),
                SizedBox(width: 12),
                Expanded(child: Text('Agregar a una playlist', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500))),
                Icon(LucideIcons.chevronRight, color: AppTheme.secondary, size: 16),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'like',
            child: Row(
              children: [
                Icon(LucideIcons.circlePlus, color: AppTheme.primary, size: 18),
                SizedBox(width: 12),
                Text('Guardar en Tus me gusta', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'queue',
            child: Row(
              children: [
                Icon(LucideIcons.listPlus, color: AppTheme.primary, size: 18),
                SizedBox(width: 12),
                Text('Agregar a la fila de reproducción', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'share',
            child: Row(
              children: [
                Icon(LucideIcons.share2, color: AppTheme.primary, size: 18),
                SizedBox(width: 12),
                Expanded(child: Text('Compartir', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500))),
                Icon(LucideIcons.chevronRight, color: AppTheme.secondary, size: 16),
              ],
            ),
          ),
        ],
      );
    }

    return IconButton(
      icon: const Icon(LucideIcons.ellipsisVertical, size: 18, color: AppTheme.secondary),
      onPressed: () => _showTrackOptionsMenu(context, ref),
      tooltip: 'Opciones',
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppTheme.surfaceHover,
      child: const Icon(LucideIcons.music, color: AppTheme.muted, size: 24),
    );
  }

  void _handleOptionSelected(BuildContext context, WidgetRef ref, String value) async {
    final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
    final dao = ref.read(playlistDaoProvider);

    if (value == 'queue') {
      if (onAddToQueue != null) {
        onAddToQueue!();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${track.title}" agregada a la cola')),
        );
      }
    } else if (value == 'like') {
      final isLiked = await dao.toggleLikeTrack(
        trackId: trackIdInt,
        artistId: 0,
        albumId: 0,
        title: track.title,
        artistName: track.artist,
        albumName: track.album ?? '',
        coverUrl: track.coverUrl,
        durationMs: (track.duration ?? Duration.zero).inMilliseconds,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isLiked ? 'Añadida a Tus me gusta' : 'Eliminada de Tus me gusta'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else if (value == 'playlist') {
      _showAddToPlaylistDialog(context, ref);
    }
  }

  void _showAddToPlaylistDialog(BuildContext context, WidgetRef ref) async {
    final dao = ref.read(playlistDaoProvider);
    final playlists = await dao.getAllPlaylists();

    if (!context.mounted) return;

    if (playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tienes playlists creadas. Crea una en tu biblioteca.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Agregar a playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 300,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: playlists.length,
            itemBuilder: (c, i) {
              final pl = playlists[i];
              return ListTile(
                leading: const Icon(LucideIcons.music, color: AppTheme.primary),
                title: Text(pl.title, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
                subtitle: Text(pl.isLiked ? 'Especial' : (pl.description ?? 'Playlist'), style: const TextStyle(color: AppTheme.secondary, fontSize: 12)),
                onTap: () async {
                  final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
                  await dao.addTrackToPlaylist(
                    playlistId: pl.id,
                    trackId: trackIdInt,
                    artistId: 0,
                    albumId: 0,
                    title: track.title,
                    artistName: track.artist,
                    albumName: track.album ?? '',
                    coverUrl: track.coverUrl,
                    durationMs: (track.duration ?? Duration.zero).inMilliseconds,
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Agregada a "${pl.title}"')),
                    );
                  }
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _showTrackOptionsMenu(BuildContext context, WidgetRef ref) {
    AppBottomSheet.show(
      context: context,
      title: track.title,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _OptionItem(
            icon: LucideIcons.listPlus,
            label: 'Agregar a la cola',
            onTap: () {
              Navigator.pop(context);
              _handleOptionSelected(context, ref, 'queue');
            },
          ),
          _OptionItem(
            icon: LucideIcons.heart,
            label: 'Agregar a Me Gusta',
            onTap: () {
              Navigator.pop(context);
              _handleOptionSelected(context, ref, 'like');
            },
          ),
          _OptionItem(
            icon: LucideIcons.folderPlus,
            label: 'Agregar a playlist',
            onTap: () {
              Navigator.pop(context);
              _handleOptionSelected(context, ref, 'playlist');
            },
          ),
        ],
      ),
    );
  }
}

/// Fila de opción estilizada para el menú de 3 puntos del track.
class _OptionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _OptionItem({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.primary, size: 20),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
