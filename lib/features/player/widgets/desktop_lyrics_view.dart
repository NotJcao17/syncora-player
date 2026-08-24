import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/apis/lrclib_api.dart';
import '../../../data/apis/lrclib_provider.dart';
import '../player_models.dart';
import '../player_providers.dart';

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
  int _lastHighlightedIndex = -1;

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
        _lastHighlightedIndex = -1;
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

  void _scrollToCurrentLine(int activeIndex) {
    if (activeIndex != _lastHighlightedIndex && _scrollController.hasClients) {
      _lastHighlightedIndex = activeIndex;
      final viewportHeight = _scrollController.position.viewportDimension;
      // Estimar 64px por línea de letra en karaoke desktop espacioso
      final targetOffset = (activeIndex * 64.0) - (viewportHeight * 0.35);
      _scrollController.animateTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPosition = ref.watch(playerStateProvider).engine.position;

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
                        ? _buildSyncedKaraokeDesktop(currentPosition)
                        : _buildPlainLyricsDesktop(),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncedKaraokeDesktop(Duration currentPosition) {
    final lines = _lyricsResult!.lines;

    int activeIndex = -1;
    for (int i = 0; i < lines.length; i++) {
      if (currentPosition >= lines[i].timestamp) {
        activeIndex = i;
      } else {
        break;
      }
    }

    if (activeIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrentLine(activeIndex);
      });
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 80),
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final line = lines[index];
            final isActive = index == activeIndex;
            final isPast = index < activeIndex;

            return _DesktopLyricsLineTile(
              line: line,
              isActive: isActive,
              isPast: isPast,
              onTap: () {
                ref.read(syncoraPlayerControllerProvider.notifier).seek(line.timestamp);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildPlainLyricsDesktop() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
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
    );
  }
}

class _DesktopLyricsLineTile extends StatefulWidget {
  final LrcLine line;
  final bool isActive;
  final bool isPast;
  final VoidCallback onTap;

  const _DesktopLyricsLineTile({
    required this.line,
    required this.isActive,
    required this.isPast,
    required this.onTap,
  });

  @override
  State<_DesktopLyricsLineTile> createState() => _DesktopLyricsLineTileState();
}

class _DesktopLyricsLineTileState extends State<_DesktopLyricsLineTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    Color textColor;
    if (widget.isActive) {
      textColor = Colors.white;
    } else if (_isHovered) {
      textColor = Colors.white.withValues(alpha: 0.9);
    } else if (widget.isPast) {
      textColor = AppTheme.secondary.withValues(alpha: 0.5);
    } else {
      textColor = AppTheme.secondary.withValues(alpha: 0.8);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            style: TextStyle(
              fontSize: widget.isActive ? 28 : 22,
              fontWeight: widget.isActive ? FontWeight.w900 : FontWeight.w700,
              color: textColor,
              height: 1.4,
              shadows: widget.isActive ? AppTheme.textGlow : null,
            ),
            child: Text(
              widget.line.text.isEmpty ? '♪' : widget.line.text,
            ),
          ),
        ),
      ),
    );
  }
}
