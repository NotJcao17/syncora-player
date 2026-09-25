import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../stats_models.dart';
import '../stats_providers.dart';
import '../../../core/cache/app_image_cache.dart';

/// Contenedor común de todas las secciones del dashboard, para que el
/// espaciado y el borde no se repitan en cada una.
class StatsPanel extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? action;

  const StatsPanel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// Una de las cuatro cifras grandes de la cabecera.
class KpiTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  /// Variación respecto al periodo anterior, como fracción (0.18 = +18 %).
  final double? trend;

  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.trend,
  });

  @override
  Widget build(BuildContext context) {
    final t = trend;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: AppTheme.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(
                color: AppTheme.primary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
          ),
          if (t != null) ...[
            const SizedBox(height: 4),
            Text(
              '${t >= 0 ? '+' : ''}${(t * 100).round()} % vs antes',
              style: TextStyle(
                color: t >= 0 ? const Color(0xFF6EE7B7) : AppTheme.error,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Podio de artistas: los tres primeros en grande con foto, el resto en
/// lista compacta.
class TopArtistsPodium extends StatelessWidget {
  final List<EnrichedArtist> artists;
  final int totalMs;

  const TopArtistsPodium({super.key, required this.artists, required this.totalMs});

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) {
      return const Text('Sin datos en este periodo',
          style: TextStyle(color: AppTheme.muted, fontSize: 12));
    }

    final podium = artists.take(3).toList();
    final rest = artists.skip(3).toList();

    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < podium.length; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _PodiumSlot(rank: i + 1, item: podium[i]),
                ),
              ),
            // Rellena para que con uno o dos artistas no se estiren al ancho
            // completo y parezcan otra cosa.
            for (var i = podium.length; i < 3; i++) const Expanded(child: SizedBox()),
          ],
        ),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 16),
          for (var i = 0; i < rest.length; i++)
            _ArtistRow(rank: i + 4, item: rest[i], totalMs: totalMs),
        ],
      ],
    );
  }
}

class _PodiumSlot extends StatelessWidget {
  final int rank;
  final EnrichedArtist item;

  const _PodiumSlot({required this.rank, required this.item});

  @override
  Widget build(BuildContext context) {
    final size = rank == 1 ? 84.0 : 64.0;
    return Column(
      children: [
        Stack(
          alignment: Alignment.bottomCenter,
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: rank == 1 ? AppTheme.accent : Colors.white.withValues(alpha: 0.12),
                  width: rank == 1 ? 2.5 : 1.5,
                ),
              ),
              child: ClipOval(
                child: item.artist.pictureUrl.isEmpty
                    ? Container(
                        color: AppTheme.surfaceHover,
                        child: const Icon(Icons.person, color: AppTheme.muted),
                      )
                    : CachedNetworkImage(
                        cacheManager: AppImageCache.instance,
                        imageUrl: item.artist.pictureUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => Container(color: AppTheme.surfaceHover),
                        errorWidget: (_, _, _) => Container(
                          color: AppTheme.surfaceHover,
                          child: const Icon(Icons.person, color: AppTheme.muted),
                        ),
                      ),
              ),
            ),
            Positioned(
              bottom: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: rank == 1 ? AppTheme.accent : AppTheme.surfaceActive,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$rank',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          item.artist.name,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppTheme.primary,
            fontSize: rank == 1 ? 13 : 12,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          formatListeningTime(item.entry.ms),
          style: const TextStyle(color: AppTheme.muted, fontSize: 11),
        ),
      ],
    );
  }
}

class _ArtistRow extends StatelessWidget {
  final int rank;
  final EnrichedArtist item;
  final int totalMs;

  const _ArtistRow({required this.rank, required this.item, required this.totalMs});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text('$rank',
                style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          ),
          ClipOval(
            child: SizedBox(
              width: 30,
              height: 30,
              child: item.artist.pictureUrl.isEmpty
                  ? Container(color: AppTheme.surfaceHover)
                  : CachedNetworkImage(cacheManager: AppImageCache.instance, imageUrl: item.artist.pictureUrl, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.artist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.primary, fontSize: 13),
            ),
          ),
          Text(
            formatListeningTime(item.entry.ms),
            style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Lista de canciones con portada, minutos y número de reproducciones, sobre
/// una barra de proporción que da la lectura relativa de un vistazo.
class TopTracksList extends StatelessWidget {
  final List<EnrichedTrack> tracks;

  const TopTracksList({super.key, required this.tracks});

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return const Text('Sin datos en este periodo',
          style: TextStyle(color: AppTheme.muted, fontSize: 12));
    }
    final maxMs = tracks.first.entry.ms;

    return Column(
      children: [
        for (var i = 0; i < tracks.length; i++)
          _TrackRow(rank: i + 1, item: tracks[i], maxMs: maxMs),
      ],
    );
  }
}

class _TrackRow extends StatelessWidget {
  final int rank;
  final EnrichedTrack item;
  final int maxMs;

  const _TrackRow({required this.rank, required this.item, required this.maxMs});

  @override
  Widget build(BuildContext context) {
    final fraction = maxMs == 0 ? 0.0 : (item.entry.ms / maxMs).clamp(0.0, 1.0);
    final plays = item.entry.plays;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Stack(
        children: [
          // Barra de proporción de fondo.
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: Text('$rank',
                      style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: item.track.coverUrl.isEmpty
                        ? Container(color: AppTheme.surfaceHover)
                        : CachedNetworkImage(cacheManager: AppImageCache.instance, imageUrl: item.track.coverUrl, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppTheme.primary, fontSize: 13),
                      ),
                      if (item.track.artistName.isNotEmpty)
                        Text(
                          item.track.artistName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (plays > 0)
                      Text(
                        plays == 1 ? '1 repr.' : '$plays repr.',
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(
                      formatListeningTime(item.entry.ms),
                      style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Barras horizontales de géneros, con porcentaje sobre el total del
/// periodo.
class GenreBars extends StatelessWidget {
  final List<GenreEntry> genres;

  const GenreBars({super.key, required this.genres});

  static const _palette = [
    AppTheme.genrePop,
    AppTheme.genreRock,
    AppTheme.genreElectronic,
    AppTheme.genreHipHop,
    AppTheme.accent,
  ];

  @override
  Widget build(BuildContext context) {
    if (genres.isEmpty) {
      return const Text(
        'Todavía no hay géneros. Se resuelven en segundo plano a partir del '
        'álbum de cada canción, así que aparecerán en los próximos arranques.',
        style: TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.4),
      );
    }

    final top = genres.take(5).toList();
    final otherMs = genres.skip(5).fold<int>(0, (s, g) => s + g.ms);
    final totalMs = genres.fold<int>(0, (s, g) => s + g.ms);
    if (totalMs == 0) return const SizedBox.shrink();

    final maxMs = top.first.ms;

    return Column(
      children: [
        for (var i = 0; i < top.length; i++)
          _GenreBar(
            label: top[i].genre,
            ms: top[i].ms,
            fraction: top[i].ms / maxMs,
            percent: top[i].ms / totalMs,
            color: _palette[i % _palette.length],
          ),
        if (otherMs > 0)
          _GenreBar(
            label: 'Otros',
            ms: otherMs,
            fraction: otherMs / maxMs,
            percent: otherMs / totalMs,
            color: AppTheme.muted,
          ),
      ],
    );
  }
}

class _GenreBar extends StatelessWidget {
  final String label;
  final int ms;
  final double fraction;
  final double percent;
  final Color color;

  const _GenreBar({
    required this.label,
    required this.ms,
    required this.fraction,
    required this.percent,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.primary, fontSize: 12),
                ),
              ),
              Text(
                '${(percent * 100).round()} % · ${formatListeningTime(ms)}',
                style: const TextStyle(color: AppTheme.muted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              minHeight: 7,
              backgroundColor: Colors.white.withValues(alpha: 0.05),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}
