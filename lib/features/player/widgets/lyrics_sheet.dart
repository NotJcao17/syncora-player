import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/apis/lrclib_api.dart';
import '../../../data/apis/lrclib_provider.dart';
import '../player_models.dart';
import '../player_providers.dart';

class LyricsSheet extends ConsumerStatefulWidget {
  final SyncoraTrack track;

  const LyricsSheet({super.key, required this.track});

  @override
  ConsumerState<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends ConsumerState<LyricsSheet> {
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
  void didUpdateWidget(covariant LyricsSheet oldWidget) {
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
      final targetOffset = (activeIndex * 48.0) - 120.0;
      _scrollController.animateTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPosition = ref.watch(playerStateProvider.select((s) => s.engine.position));

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.secondary.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Icon(AppIcons.broken(SolarIcons.Microphone), color: AppTheme.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.track.title,
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.track.artist,
                        style: const TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(color: AppTheme.surfaceHover, height: 1),

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
                            Icon(AppIcons.broken(SolarIcons.Album), size: 48, color: AppTheme.secondary),
                            const SizedBox(height: 12),
                            const Text(
                              'No se encontraron letras para esta canción',
                              style: TextStyle(color: AppTheme.secondary, fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    : _lyricsResult!.hasSynced
                        ? _buildSyncedKaraokeView(currentPosition)
                        : _buildPlainLyricsView(),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncedKaraokeView(Duration currentPosition) {
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

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        final isActive = index == activeIndex;
        final isPast = index < activeIndex;

        return InkWell(
          onTap: () {
            ref.read(syncoraPlayerControllerProvider.notifier).seek(line.timestamp);
          },
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                fontSize: isActive ? 22 : 16,
                fontWeight: isActive ? FontWeight.w900 : FontWeight.w500,
                color: isActive
                    ? AppTheme.primary
                    : (isPast ? AppTheme.secondary.withValues(alpha: 0.6) : AppTheme.secondary),
              ),
              child: Text(line.text.isEmpty ? '♪' : line.text),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlainLyricsView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Text(
        _lyricsResult!.plainLyrics!,
        style: const TextStyle(
          color: AppTheme.primary,
          fontSize: 16,
          height: 1.8,
        ),
      ),
    );
  }
}
