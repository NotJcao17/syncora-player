import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/apis/lrclib_api.dart';
import '../../../data/apis/lrclib_provider.dart';
import '../player_models.dart';
import '../player_providers.dart';
import 'synced_lyrics_list.dart';
import '../../../core/cache/app_image_cache.dart';

/// Vista de letras para pantalla de escritorio (Spotify Desktop Lyrics style).
class DesktopLyricsView extends ConsumerStatefulWidget {
  final SyncoraTrack track;

  const DesktopLyricsView({super.key, required this.track});

  @override
  ConsumerState<DesktopLyricsView> createState() => _DesktopLyricsViewState();
}

class _DesktopLyricsViewState extends ConsumerState<DesktopLyricsView> {
  LRCLibResult? _lyricsResult;
  bool _isLoading = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchLyrics();
  }

  @override
  void didUpdateWidget(covariant DesktopLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id) {
      setState(() {
        _isLoading = true;
        _lyricsResult = null;
      });
      _fetchLyrics();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchLyrics() async {
    final lrcApi = ref.read(lrcLibApiProvider);
    final durationSec = widget.track.duration?.inSeconds ?? 180;
    final res = await lrcApi.getLyrics(
      cacheKey: widget.track.id,
      trackTitle: widget.track.title,
      artistName: widget.track.artist,
      durationSec: durationSec,
    );

    if (mounted) {
      setState(() {
        _lyricsResult = res;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF1E2633),
            Color(0xFF131722),
          ],
        ),
      ),
      child: Column(
        children: [
          // Header de la vista de letras
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 20, 32, 16),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: widget.track.coverUrl.isNotEmpty
                        ? CachedNetworkImage(
                            cacheManager: AppImageCache.instance,
                            imageUrl: widget.track.coverUrl,
                            fit: BoxFit.cover,
                            memCacheWidth: 100,
                            memCacheHeight: 100,
                            placeholder: (context, url) => Container(color: AppTheme.surfaceHover),
                            errorWidget: (context, url, error) => Container(
                              color: AppTheme.surfaceHover,
                              child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 20),
                            ),
                          )
                        : Container(
                            color: AppTheme.surfaceHover,
                            child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 20),
                          ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: 'Cerrar letras',
                  child: IconButton(
                    icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary, size: 24),
                    onPressed: () {
                      ref.read(isLyricsOpenProvider.notifier).state = false;
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: AppTheme.surfaceHover, height: 1),

          // Contenido central de letras
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppTheme.primary),
                  )
                : _lyricsResult == null || _lyricsResult!.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(AppIcons.broken(SolarIcons.Microphone), size: 56, color: AppTheme.secondary),
                            const SizedBox(height: 16),
                            const Text(
                              'No se encontraron letras para esta canción',
                              style: TextStyle(
                                color: AppTheme.secondary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      )
                    : _lyricsResult!.hasSynced
                        ? _buildSyncedKaraokeDesktop()
                        : _buildPlainLyricsDesktop(),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncedKaraokeDesktop() {
    return SyncedLyricsList(
      lines: _lyricsResult!.lines,
      fontSize: 24,
      activeScale: 1.18,
      lineSpacing: 12,
      maxWidth: 760,
      showScrollbar: true,
      glow: true,
      listPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 160),
    );
  }

  Widget _buildPlainLyricsDesktop() {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                _lyricsResult!.plainLyrics!,
                textAlign: TextAlign.left,
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  height: 2.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
