import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../utils/connectivity_service.dart';
import '../utils/contributor_resolver.dart';
import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/supabase/supabase_providers.dart';
import '../../features/download/download_provider.dart';
import '../../features/player/player_models.dart';
import '../../features/player/player_providers.dart';
import 'app_bottom_sheet.dart';
import 'app_toast.dart';

/// Componente de fila de canción reutilizable.
class TrackTile extends ConsumerStatefulWidget {
  final SyncoraTrack track;
  final int? index;
  final bool isPlaying;
  final bool isDownloaded;
  final bool isAvailable;
  final bool showAlbum;
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
    this.showAlbum = false,
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

    final isAudioPlaying = ref.watch(isPlayingProvider);
    final isActiveTrack = widget.isPlaying;
    final isPlayingActive = isActiveTrack && isAudioPlaying;
    final isPausedActive = isActiveTrack && !isAudioPlaying;

    final isConnectedAsync = ref.watch(isConnectedProvider);
    final isConnected = isConnectedAsync.value ?? true;

    final trackDeezerId = int.tryParse(widget.track.id) ?? widget.track.id.hashCode.abs();

    final downloadedTrackAsync = ref.watch(watchDownloadedTrackProvider(trackDeezerId));
    final downloadedTrack = downloadedTrackAsync.value;

    final isDownloadedLocal = (downloadedTrack?.downloadState == 2) || widget.isDownloaded;
    final isDownloadingLocal = downloadedTrack?.downloadState == 1;

    final isPlayable = isConnected || isDownloadedLocal;

    const activeColor = Color(0xFF22C55E);

    final textColor = isPlayable
        ? (isActiveTrack ? activeColor : AppTheme.primary)
        : AppTheme.muted;
    final subtitleColor = isPlayable ? AppTheme.secondary : AppTheme.muted;

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

    if (widget.index == null && isActiveTrack) {
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
              child: isPlayingActive
                  ? (_isHovered
                      ? Icon(
                          AppIcons.bold(SolarIcons.Pause),
                          color: activeColor,
                          size: 18,
                        )
                      : LoadingAnimationWidget.staggeredDotsWave(
                          color: activeColor,
                          size: 18,
                        ))
                  : (_isHovered
                      ? Icon(
                          AppIcons.bold(SolarIcons.Play),
                          color: activeColor,
                          size: 18,
                        )
                      : Icon(
                          AppIcons.bold(SolarIcons.Play),
                          color: activeColor.withValues(alpha: 0.7),
                          size: 18,
                        )),
            ),
          ),
        ],
      );
    }

    Widget content = Opacity(
      opacity: isPlayable ? 1.0 : 0.4,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: InkWell(
          onTap: () {
            if (!isPlayable) {
              AppToast.show(context, message: 'No disponible sin conexión');
              return;
            }
            if (isPlayingActive) {
              ref.read(syncoraPlayerControllerProvider.notifier).pause();
            } else if (widget.onTap != null) {
              widget.onTap!();
            } else if (isPausedActive) {
              ref.read(syncoraPlayerControllerProvider.notifier).play();
            }
          },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: isActiveTrack
                  ? AppTheme.surfaceHover.withValues(alpha: 0.6)
                  : (_isHovered ? AppTheme.surfaceHover.withValues(alpha: 0.3) : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // Número / Play / Pause
                  if (widget.index != null) ...[
                    SizedBox(
                      width: 28,
                      child: Center(
                        child: isPlayingActive
                            ? (_isHovered
                                ? Icon(
                                    AppIcons.bold(SolarIcons.Pause),
                                    color: activeColor,
                                    size: 18,
                                  )
                                : LoadingAnimationWidget.staggeredDotsWave(
                                    color: activeColor,
                                    size: 18,
                                  ))
                            : (isPausedActive
                                ? (_isHovered
                                    ? Icon(
                                        AppIcons.bold(SolarIcons.Play),
                                        color: activeColor,
                                        size: 18,
                                      )
                                    : Text(
                                        '${widget.index! + 1}',
                                        style: const TextStyle(
                                          color: activeColor,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        textAlign: TextAlign.center,
                                      ))
                                : (isDesktop && _isHovered
                                    ? Icon(
                                        AppIcons.bold(SolarIcons.Play),
                                        color: AppTheme.primary,
                                        size: 18,
                                      )
                                    : Text(
                                        '${widget.index! + 1}',
                                        style: TextStyle(
                                          color: AppTheme.secondary.withValues(alpha: 0.7),
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        textAlign: TextAlign.center,
                                      ))),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],

                  // Portada + Título + Artista
                  Expanded(
                    flex: (isDesktop && widget.showAlbum) ? 3 : 1,
                    child: Row(
                      children: [
                        coverWidget,
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                widget.track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 14,
                                  fontWeight: isActiveTrack ? FontWeight.bold : FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              _buildSubtitle(context, subtitleColor, isDownloadingLocal, isDownloadedLocal, isConnected),

                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                // Columna Álbum en Desktop
                if (isDesktop && widget.showAlbum) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Text(
                      (widget.track.album != null && widget.track.album!.isNotEmpty)
                          ? widget.track.album!
                          : '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.secondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],

                const SizedBox(width: 12),

                // Duración en Desktop
                if (isDesktop && widget.track.duration != null) ...[
                  SizedBox(
                    width: 50,
                    child: Text(
                      _formatDuration(widget.track.duration!),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: AppTheme.secondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],

                // Botón de 3 Puntos u Opciones
                _buildMoreButton(context),
              ],
            ),
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
        confirmDismiss: (direction) async {
          widget.onAddToQueue!();
          AppToast.show(context, message: '"${widget.track.title}" agregada a la cola');
          return false; // Retornar false para no eliminar visualmente la canción de la lista
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

  Widget _buildSubtitle(
    BuildContext context,
    Color subtitleColor,
    bool isDownloadingLocal,
    bool isDownloadedLocal,
    bool isConnected,
  ) {
    Widget? statusIcon;
    if (isDownloadingLocal) {
      statusIcon = const Padding(
        padding: EdgeInsets.only(right: 6),
        child: SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: AppTheme.secondary,
          ),
        ),
      );
    } else if (isDownloadedLocal) {
      statusIcon = Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Icon(
          AppIcons.bold(SolarIcons.DownloadMinimalistic),
          color: AppTheme.secondary,
          size: 13,
        ),
      );
    } else if (!isConnected) {
      statusIcon = Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Icon(
          AppIcons.broken(SolarIcons.WiFiRouter),
          color: const Color(0xFFF59E0B),
          size: 13,
        ),
      );
    }

    final isDesktop = MediaQuery.of(context).size.width >= 768;

    if (!isDesktop) {
      return Row(
        children: [
          if (statusIcon != null) statusIcon,
          Expanded(
            child: Text(
              widget.track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: subtitleColor,
                fontSize: 13,
              ),
            ),
          ),
        ],
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

      return Row(
        children: [
          if (statusIcon != null) statusIcon,
          Expanded(
            child: Text.rich(
              TextSpan(children: spans),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    final hasArtistId = widget.track.artistId != null && widget.track.artistId != 0;

    if (hasArtistId) {
      return Row(
        children: [
          if (statusIcon != null) statusIcon,
          Expanded(
            child: Text.rich(
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
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        if (statusIcon != null) statusIcon,
        Expanded(
          child: Text(
            widget.track.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
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

    final trackIdInt = int.tryParse(widget.track.id) ?? widget.track.id.hashCode.abs();

    return FutureBuilder<bool>(
      future: ref.read(playlistDaoProvider).isTrackLiked(trackIdInt),
      builder: (context, snapshot) {
        final isLiked = snapshot.data ?? false;

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
                    Icon(isLiked ? AppIcons.bold(SolarIcons.Heart) : AppIcons.broken(SolarIcons.Heart), color: AppTheme.primary, size: 18),
                    const SizedBox(width: 12),
                    Text(isLiked ? 'Eliminar de Me Gusta' : 'Guardar en Tus me gusta', style: const TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w500)),
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
      },
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
      final contributors = await resolveTrackContributors(ref.read(deezerApiProvider), widget.track);
      final isLiked = await dao.toggleLikeTrack(
        trackId: trackIdInt,
        artistId: widget.track.artistId ?? 0,
        albumId: widget.track.albumId ?? 0,
        title: widget.track.title,
        artistName: widget.track.artist,
        albumName: widget.track.album ?? '',
        coverUrl: widget.track.coverUrl,
        durationMs: (widget.track.duration ?? Duration.zero).inMilliseconds,
        contributorsJson: SyncoraArtistRef.encodeList(contributors),
      );
      final likedPlaylist = await dao.getLikedPlaylist();
      final wasLocalOnly = likedPlaylist.remoteId == null;
      var likedRemoteId = likedPlaylist.remoteId;
      final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);

      if (likedRemoteId == null) {
        try {
          final res = await supabaseRepo.getOrCreateLikedPlaylist();
          likedRemoteId = res['id']?.toString();
          // `remoteId` NO se escribe en local todavía — mismo motivo que en
          // "Agregar a playlist" más abajo: escribirlo antes de respaldar lo
          // que ya había habilita sync automático contra un remoto vacío/a
          // medias y termina podando "Tus me gusta" local.
        } catch (_) {}
      }

      // Si "Tus me gusta" era solo local (típico si el usuario acumuló likes
      // antes de iniciar sesión, o antes de que existiera este respaldo) y
      // recién le creamos su contraparte remota, hay que subir TODO el
      // estado actual de una — `toggleLikeTrack` ya corrió arriba, así que
      // esta lista ya incluye (o excluye) la pista que se acaba de tocar.
      var likedBackfillOk = true;
      if (wasLocalOnly && likedRemoteId != null) {
        try {
          final existingTracks = await dao.getTracksOrdered(likedPlaylist.id);
          if (existingTracks.isNotEmpty) {
            await supabaseRepo.addTracksToPlaylist(
              likedRemoteId,
              existingTracks
                  .map((t) => {
                        'track_id': t.trackId,
                        'artist_id': t.artistId,
                        'album_id': t.albumId,
                        'title': t.title,
                        'artist_name': t.artistName,
                        'album_name': t.albumName,
                        'cover_url': t.coverUrl,
                        'duration_ms': t.durationMs,
                        if (t.genre != null) 'genre': t.genre,
                        if (t.contributorsJson != null) 'contributors_json': t.contributorsJson,
                      })
                  .toList(),
            );
          }
        } catch (_) {
          likedBackfillOk = false;
        }
      }

      if (likedRemoteId != null) {
        // Si era local-only, el backfill de arriba ya subió el estado
        // completo (incluida esta pista) — no hace falta aplicar el cambio
        // puntual encima, sería redundante.
        if (!wasLocalOnly) {
          try {
            if (isLiked) {
              await supabaseRepo.addTrackToPlaylist(likedRemoteId, {
                'track_id': trackIdInt,
                'artist_id': widget.track.artistId ?? 0,
                'album_id': widget.track.albumId ?? 0,
                'title': widget.track.title,
                'artist_name': widget.track.artist,
                'album_name': widget.track.album ?? '',
                'cover_url': widget.track.coverUrl,
                'duration_ms': (widget.track.duration ?? Duration.zero).inMilliseconds,
                'genre': widget.track.genre,
                if (contributors.isNotEmpty) 'contributors_json': SyncoraArtistRef.encodeList(contributors),
              });
            } else {
              await supabaseRepo.removeTrackFromPlaylist(likedRemoteId, trackIdInt);
            }
          } catch (_) {
            if (context.mounted) {
              AppToast.show(context, message: 'La playlist ya no existe en la nube');
            }
          }
        }

        if (wasLocalOnly && likedBackfillOk) {
          try {
            await dao.updatePlaylist(likedPlaylist.copyWith(remoteId: Value(likedRemoteId)));
          } catch (_) {}
        }
      }
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
                  var remoteId = pl.remoteId;
                  final wasLocalOnly = remoteId == null;
                  final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                  if (remoteId == null) {
                    try {
                      final created = pl.isLiked
                          ? await supabaseRepo.getOrCreateLikedPlaylist()
                          : await supabaseRepo.createPlaylist(
                              title: pl.title,
                              description: pl.description,
                              isPublic: pl.isPublic,
                              isLiked: pl.isLiked,
                            );
                      remoteId = created['id']?.toString();
                      // OJO: `remoteId` NO se escribe en la playlist local
                      // todavía aquí — recién al final, después de que se
                      // suban también las pistas existentes. Escribirlo de
                      // una causó un bug real: en cuanto la playlist local
                      // tiene `remoteId`, abrirla dispara sync automático
                      // (`playlist_detail_screen.dart`), que trata el remoto
                      // como fuente de verdad y poda lo local que no esté
                      // ahí — y el remoto recién creado está vacío.
                    } catch (_) {}
                  }

                  // Si la playlist era solo local (ej. importada desde CSV)
                  // y recién le creamos su contraparte remota, hay que subir
                  // TODAS sus pistas existentes ahora, no solo la nueva que
                  // se está agregando. Si no, la próxima sincronización ve
                  // un remoto más flaco que lo local y PODA todo lo que no
                  // esté ahí (`sync_service.dart`, `_syncPlaylistsAndTracks`
                  // trata el remoto como fuente de verdad) — borrando la
                  // playlist importada casi entera. Bug real reportado en
                  // vivo: se agregaba UNA canción y desaparecía el resto.
                  var existingTracksUploadOk = true;
                  if (wasLocalOnly && remoteId != null) {
                    try {
                      final existingTracks = await dao.getTracksOrdered(pl.id);
                      if (existingTracks.isNotEmpty) {
                        await supabaseRepo.addTracksToPlaylist(
                          remoteId,
                          existingTracks
                              .map((t) => {
                                    'track_id': t.trackId,
                                    'artist_id': t.artistId,
                                    'album_id': t.albumId,
                                    'title': t.title,
                                    'artist_name': t.artistName,
                                    'album_name': t.albumName,
                                    'cover_url': t.coverUrl,
                                    'duration_ms': t.durationMs,
                                    if (t.genre != null) 'genre': t.genre,
                                    if (t.contributorsJson != null) 'contributors_json': t.contributorsJson,
                                  })
                              .toList(),
                        );
                      }
                    } catch (_) {
                      existingTracksUploadOk = false;
                    }
                  }

                  final contributors = await resolveTrackContributors(ref.read(deezerApiProvider), widget.track);

                  if (remoteId != null) {
                    try {
                      await supabaseRepo.addTrackToPlaylist(remoteId, {
                        'track_id': trackIdInt,
                        'artist_id': widget.track.artistId ?? 0,
                        'album_id': widget.track.albumId ?? 0,
                        'title': widget.track.title,
                        'artist_name': widget.track.artist,
                        'album_name': widget.track.album ?? '',
                        'cover_url': widget.track.coverUrl,
                        'duration_ms': (widget.track.duration ?? Duration.zero).inMilliseconds,
                        'genre': widget.track.genre,
                        if (contributors.isNotEmpty) 'contributors_json': SyncoraArtistRef.encodeList(contributors),
                      });
                    } catch (_) {
                      if (context.mounted) {
                        AppToast.show(context, message: 'La playlist ya no existe en la nube');
                      }
                      if (!pl.isLiked) {
                        await dao.deletePlaylist(pl.id);
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      return;
                    }

                    // Recién ahora, con el remoto ya al día (pistas viejas +
                    // la nueva), se marca la playlist local como respaldada
                    // — es la señal que habilita la sincronización
                    // automática al abrirla. Si la subida de las pistas
                    // existentes falló arriba, se deja sin `remoteId` a
                    // propósito: mejor quedarse local-only (seguro, ninguna
                    // sync la toca) que marcarla sincronizada con un remoto
                    // incompleto.
                    if (wasLocalOnly && existingTracksUploadOk) {
                      try {
                        await dao.updatePlaylist(pl.copyWith(remoteId: Value(remoteId)));
                      } catch (_) {}
                    }
                  }

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
                    contributorsJson: SyncoraArtistRef.encodeList(contributors),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    AppToast.show(context, message: 'Agregada a "${pl.title}"');
                  }
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _showTrackOptionsMenu(BuildContext context, WidgetRef ref) async {
    final trackIdInt = int.tryParse(widget.track.id) ?? widget.track.id.hashCode.abs();
    final isLiked = await ref.read(playlistDaoProvider).isTrackLiked(trackIdInt);

    if (!context.mounted) return;

    AppBottomSheet.show(
      context: context,
      title: widget.track.title,
      child: ListView(
        shrinkWrap: true,
        physics: const ClampingScrollPhysics(),
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
            icon: isLiked ? AppIcons.bold(SolarIcons.Heart) : AppIcons.broken(SolarIcons.Heart),
            label: isLiked ? 'Eliminar de Me Gusta' : 'Agregar a Me Gusta',
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

