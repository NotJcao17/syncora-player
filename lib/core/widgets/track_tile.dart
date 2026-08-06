import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../../data/local_db/database_provider.dart';
import '../../features/player/player_models.dart';
import 'app_bottom_sheet.dart';
import 'app_toast.dart';

/// Componente de fila de canción reutilizable.
class TrackTile extends ConsumerStatefulWidget {
  final SyncoraTrack track;
  final int? index;
  final bool isPlaying;
  final bool isDownloaded;
  final bool isAvailable;
  final VoidCallback? onTap;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onMorePressed;
  final VoidCallback? onRemove;

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
    this.onRemove,
  });

  @override
  ConsumerState<TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends ConsumerState<TrackTile> {
  bool _isHovered = false;

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 768;
    final isMobile = screenWidth < 768;

    final textColor = widget.isAvailable
        ? (widget.isPlaying ? AppTheme.primary : AppTheme.primary)
        : AppTheme.muted;
    final subtitleColor = widget.isAvailable ? AppTheme.secondary : AppTheme.muted;

    // Portada base de 48x48
    Widget coverWidget = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 48,
        height: 48,
        child: widget.track.coverUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: widget.track.coverUrl,
                memCacheWidth: 300,
                fit: BoxFit.cover,
                errorWidget: (context, url, error) => _buildPlaceholder(),
                placeholder: (context, url) => Container(color: AppTheme.surfaceHover),
              )
            : _buildPlaceholder(),
      ),
    );

    // Tarea 6: Si index == null y isPlaying == true, mostrar indicador animado sobre la portada
    if (widget.index == null && widget.isPlaying) {
      coverWidget = Stack(
        children: [
          coverWidget,
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: LoadingAnimationWidget.staggeredDotsWave(
                color: AppTheme.primary,
                size: 18,
              ),
            ),
          ),
        ],
      );
    }

    Widget content = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.isAvailable ? widget.onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            color: widget.isPlaying ? AppTheme.surfaceHover.withValues(alpha: 0.6) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // Tarea 4 & 5 & 6: Número o Indicador de reproducción (solo si widget.index != null)
                if (widget.index != null) ...[
                  SizedBox(
                    width: 28,
                    child: Center(
                      child: widget.isPlaying
                          ? LoadingAnimationWidget.staggeredDotsWave(
                              color: AppTheme.primary,
                              size: 18,
                            )
                          : (isDesktop && _isHovered
                              ? Icon(
                                  AppIcons.bold(SolarIcons.Play),
                                  color: AppTheme.primary,
                                  size: 18,
                                )
                              : Text(
                                  '${widget.index! + 1}',
                                  style: TextStyle(
                                    color: widget.isPlaying
                                        ? AppTheme.primary
                                        : AppTheme.secondary.withValues(alpha: 0.7),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  textAlign: TextAlign.center,
                                )),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],

                // Portada
                coverWidget,
                const SizedBox(width: 12),

                // Título y Artista / Álbum (Tarea 8)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          if (widget.isDownloaded) ...[
                            Icon(
                              AppIcons.bold(SolarIcons.CheckCircle),
                              color: AppTheme.primary,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              widget.track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: textColor,
                                fontSize: 14,
                                fontWeight: widget.isPlaying ? FontWeight.bold : FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      _buildSubtitle(context, subtitleColor),
                    ],
                  ),
                ),

                const SizedBox(width: 12),

                // Duración en Desktop (Tarea 10: Oculto en móvil <768px)
                if (isDesktop && widget.track.duration != null) ...[
                  Text(
                    _formatDuration(widget.track.duration!),
                    style: const TextStyle(
                      color: AppTheme.secondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],

                // Botón de 3 Puntos u Opciones Personalizadas
                _buildMoreButton(context),
              ],
            ),
          ),
        ),
      ),
    );

    // Tarea 7: Swipe para agregar a la cola en móvil
    if (isMobile && widget.onAddToQueue != null) {
      return Dismissible(
        key: Key('track_dismiss_${widget.track.id}_${widget.index}'),
        direction: DismissDirection.startToEnd,
        onDismissed: (_) {
          widget.onAddToQueue!();
          AppToast.show(context, message: '"${widget.track.title}" agregada a la cola');
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 20),
          decoration: BoxDecoration(
            color: AppTheme.surfaceActive,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(AppIcons.broken(SolarIcons.PlaylistMinimalisticN2), color: AppTheme.primary, size: 20),
              const SizedBox(width: 8),
              const Text(
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

  Widget _buildSubtitle(BuildContext context, Color subtitleColor) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    if (!isDesktop) {
      return Text(
        widget.track.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: subtitleColor,
          fontSize: 13,
        ),
      );
    }

    final style = TextStyle(
      color: subtitleColor,
      fontSize: 13,
    );

    final List<SyncoraArtistRef> effectiveArtists = [];
    if (widget.track.artists.isNotEmpty) {
      effectiveArtists.addAll(widget.track.artists);
    } else if (widget.track.artist.contains(', ')) {
      final names = widget.track.artist.split(', ');
      final mainId = widget.track.artistId ?? 0;
      for (int i = 0; i < names.length; i++) {
        effectiveArtists.add(SyncoraArtistRef(
          id: i == 0 ? mainId : 0,
          name: names[i].trim(),
        ));
      }
    }

    if (effectiveArtists.isNotEmpty) {
      final spans = <InlineSpan>[];
      for (int i = 0; i < effectiveArtists.length; i++) {
        final artist = effectiveArtists[i];
        if (i > 0) {
          spans.add(
            TextSpan(
              text: ', ',
              style: style,
            ),
          );
        }
        final isClickable = artist.id != 0;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _HoverableText(
              text: artist.name,
              style: style,
              isClickable: isClickable,
              onTap: isClickable ? () => context.push('/artist/${artist.id}') : null,
            ),
          ),
        );
      }

      return Text.rich(
        TextSpan(children: spans),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final hasArtistId = widget.track.artistId != null && widget.track.artistId != 0;

    if (hasArtistId) {
      return Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _HoverableText(
                text: widget.track.artist,
                style: style,
                isClickable: true,
                onTap: () => context.push('/artist/${widget.track.artistId}'),
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Text(
      widget.track.artist,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }

  Widget _buildMoreButton(BuildContext context) {
    if (widget.onMorePressed != null) {
      return IconButton(
        icon: Icon(AppIcons.broken(SolarIcons.MenuDots), size: 18, color: AppTheme.secondary),
        onPressed: widget.onMorePressed,
        tooltip: 'Opciones',
      );
    }

    final isDesktop = MediaQuery.of(context).size.width >= 768;

    if (isDesktop) {
      return PopupMenuButton<String>(
        icon: Icon(AppIcons.broken(SolarIcons.MenuDots), size: 18, color: AppTheme.secondary),
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
          PopupMenuItem(
            value: 'playlist',
            child: Row(
              children: [
                Icon(AppIcons.broken(SolarIcons.AddCircle), color: AppTheme.primary, size: 18),
                const SizedBox(width: 12),
                const Expanded(child: Text('Agregar a una playlist', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500))),
                Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary, size: 16),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'like',
            child: Row(
              children: [
                Icon(AppIcons.broken(SolarIcons.AddCircle), color: AppTheme.primary, size: 18),
                const SizedBox(width: 12),
                const Text('Guardar en Tus me gusta', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'queue',
            child: Row(
              children: [
                Icon(AppIcons.broken(SolarIcons.PlaylistMinimalisticN2), color: AppTheme.primary, size: 18),
                const SizedBox(width: 12),
                const Text('Agregar a la fila de reproducción', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          if (widget.onRemove != null)
            PopupMenuItem(
              value: 'remove',
              child: Row(
                children: [
                  Icon(AppIcons.broken(SolarIcons.TrashBinTrash), color: AppTheme.primary, size: 18),
                  const SizedBox(width: 12),
                  const Text('Eliminar de la playlist', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          PopupMenuItem(
            value: 'share',
            child: Row(
              children: [
                Icon(AppIcons.broken(SolarIcons.Share), color: AppTheme.primary, size: 18),
                const SizedBox(width: 12),
                const Expanded(child: Text('Compartir', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500))),
                Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary, size: 16),
              ],
            ),
          ),
        ],
      );
    }

    return IconButton(
      icon: Icon(AppIcons.broken(SolarIcons.MenuDots), size: 18, color: AppTheme.secondary),
      onPressed: () => _showTrackOptionsMenu(context, ref),
      tooltip: 'Opciones',
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppTheme.surfaceHover,
      child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 24),
    );
  }

  void _handleOptionSelected(BuildContext context, WidgetRef ref, String value) async {
    final trackIdInt = int.tryParse(widget.track.id) ?? widget.track.id.hashCode.abs();
    final dao = ref.read(playlistDaoProvider);

    if (value == 'remove') {
      if (widget.onRemove != null) {
        widget.onRemove!();
      }
    } else if (value == 'queue') {
      if (widget.onAddToQueue != null) {
        widget.onAddToQueue!();
      } else {
        AppToast.show(context, message: '"${widget.track.title}" agregada a la cola');
      }
    } else if (value == 'like') {
      final isLiked = await dao.toggleLikeTrack(
        trackId: trackIdInt,
        artistId: widget.track.artistId ?? 0,
        albumId: widget.track.albumId ?? 0,
        title: widget.track.title,
        artistName: widget.track.artist,
        albumName: widget.track.album ?? '',
        coverUrl: widget.track.coverUrl,
        durationMs: (widget.track.duration ?? Duration.zero).inMilliseconds,
      );
      if (context.mounted) {
        AppToast.show(
          context,
          message: isLiked ? 'Se agregó a Tus me gusta.' : 'Se eliminó de Tus me gusta.',
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
      AppToast.show(context, message: 'No tienes playlists creadas. Crea una en tu biblioteca.');
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
                leading: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.primary),
                title: Text(pl.title, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
                subtitle: Text(pl.isLiked ? 'Especial' : (pl.description ?? 'Playlist'), style: const TextStyle(color: AppTheme.secondary, fontSize: 12)),
                onTap: () async {
                  final trackIdInt = int.tryParse(widget.track.id) ?? widget.track.id.hashCode.abs();
                  await dao.addTrackToPlaylist(
                    playlistId: pl.id,
                    trackId: trackIdInt,
                    artistId: widget.track.artistId ?? 0,
                    albumId: widget.track.albumId ?? 0,
                    title: widget.track.title,
                    artistName: widget.track.artist,
                    albumName: widget.track.album ?? '',
                    coverUrl: widget.track.coverUrl,
                    durationMs: (widget.track.duration ?? Duration.zero).inMilliseconds,
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
      title: widget.track.title,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _OptionItem(
            icon: AppIcons.broken(SolarIcons.PlaylistMinimalisticN2),
            label: 'Agregar a la cola',
            onTap: () {
              Navigator.pop(context);
              _handleOptionSelected(context, ref, 'queue');
            },
          ),
          _OptionItem(
            icon: AppIcons.broken(SolarIcons.Heart),
            label: 'Agregar a Me Gusta',
            onTap: () {
              Navigator.pop(context);
              _handleOptionSelected(context, ref, 'like');
            },
          ),
          _OptionItem(
            icon: AppIcons.broken(SolarIcons.AddFolder),
            label: 'Agregar a playlist',
            onTap: () {
              Navigator.pop(context);
              _handleOptionSelected(context, ref, 'playlist');
            },
          ),
          if (widget.onRemove != null)
            _OptionItem(
              icon: AppIcons.broken(SolarIcons.TrashBinTrash),
              label: 'Eliminar de la playlist',
              onTap: () {
                Navigator.pop(context);
                _handleOptionSelected(context, ref, 'remove');
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

class _HoverableText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final bool isClickable;
  final VoidCallback? onTap;

  const _HoverableText({
    required this.text,
    required this.style,
    required this.isClickable,
    this.onTap,
  });

  @override
  State<_HoverableText> createState() => _HoverableTextState();
}

class _HoverableTextState extends State<_HoverableText> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.isClickable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (widget.isClickable) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (widget.isClickable) setState(() => _isHovered = false);
      },
      child: GestureDetector(
        onTap: widget.isClickable ? widget.onTap : null,
        child: Text(
          widget.text,
          style: widget.style.copyWith(
            decoration: (widget.isClickable && _isHovered) ? TextDecoration.underline : TextDecoration.none,
            decorationColor: widget.style.color,
          ),
        ),
      ),
    );
  }
}

