import 'package:flutter/material.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import 'playlist_cover_widget.dart';

enum PlaylistCardSize { small, large }

/// Componente de tarjeta de playlist/álbum (Diseño calcado del mockup index.html).
class PlaylistCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? coverUrl;
  final int? playlistId;
  final List<dynamic>? tracks;
  final bool isLiked;
  final PlaylistCardSize size;
  final VoidCallback? onTap;
  final VoidCallback? onPlayTap;

  const PlaylistCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.coverUrl,
    this.playlistId,
    this.tracks,
    this.isLiked = false,
    this.size = PlaylistCardSize.large,
    this.onTap,
    this.onPlayTap,
  });

  @override
  State<PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<PlaylistCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isLarge = widget.size == PlaylistCardSize.large;

    return InkWell(
      onTap: widget.onTap,
      onHover: (hovered) {
        if (mounted && _isHovered != hovered) {
          setState(() => _isHovered = hovered);
        }
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Portada redondeada 16px con Play button flotante
            Flexible(
              child: AspectRatio(
                aspectRatio: 1.0,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: PlaylistCoverWidget(
                        coverUrl: widget.coverUrl,
                        playlistId: widget.playlistId,
                        tracks: widget.tracks,
                        isLiked: widget.isLiked,
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    // Botón Play Flotante en hover
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity: _isHovered ? 1.0 : 0.0,
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.primary,
                            boxShadow: AppTheme.glowShadow,
                          ),
                          child: Material(
                            color: Colors.transparent,
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: IconButton(
                              style: IconButton.styleFrom(
                                shape: const CircleBorder(),
                                padding: EdgeInsets.zero,
                              ),
                              icon: Icon(
                                AppIcons.outline(SolarIcons.Play),
                                color: AppTheme.background,
                                size: 18,
                              ),
                              onPressed: widget.onPlayTap ?? widget.onTap,
                              padding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.primary,
                fontWeight: FontWeight.w800,
                fontSize: isLarge ? 14 : 13,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              widget.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.secondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
