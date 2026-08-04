import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../theme/app_theme.dart';

enum PlaylistCardSize { small, large }

/// Componente de tarjeta de playlist/álbum (Diseño calcado del mockup index.html).
class PlaylistCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? coverUrl;
  final List<String>? gridCoverUrls;
  final PlaylistCardSize size;
  final VoidCallback? onTap;
  final VoidCallback? onPlayTap;

  const PlaylistCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.coverUrl,
    this.gridCoverUrls,
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
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: _buildCoverImage(),
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
                        child: IconButton(
                          icon: const Icon(
                            LucideIcons.play,
                            color: AppTheme.background,
                            size: 18,
                          ),
                          onPressed: widget.onPlayTap ?? widget.onTap,
                          padding: EdgeInsets.zero,
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

  Widget _buildCoverImage() {
    if (widget.gridCoverUrls != null && widget.gridCoverUrls!.length >= 4) {
      return Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildSingleImage(widget.gridCoverUrls![0])),
                Expanded(child: _buildSingleImage(widget.gridCoverUrls![1])),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildSingleImage(widget.gridCoverUrls![2])),
                Expanded(child: _buildSingleImage(widget.gridCoverUrls![3])),
              ],
            ),
          ),
        ],
      );
    }

    if (widget.coverUrl != null && widget.coverUrl!.isNotEmpty) {
      return _buildSingleImage(widget.coverUrl!);
    }

    return Container(
      color: AppTheme.surfaceActive,
      child: const Icon(LucideIcons.music, color: AppTheme.muted, size: 36),
    );
  }

  Widget _buildSingleImage(String url) {
    return CachedNetworkImage(
      imageUrl: url,
      memCacheWidth: 300,
      fit: BoxFit.cover,
      placeholder: (context, url) => Container(color: AppTheme.surfaceHover),
      errorWidget: (context, url, error) => Container(
        color: AppTheme.surfaceHover,
        child: const Icon(LucideIcons.music, color: AppTheme.muted, size: 20),
      ),
    );
  }
}
