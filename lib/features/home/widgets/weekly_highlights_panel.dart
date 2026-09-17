import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../home_providers.dart';

/// Resumen de la semana en Inicio: minutos escuchados, top 3 de artistas y
/// top 3 de canciones.
///
/// Sale entero de datos locales (`listening_history` + el caché de metadatos de
/// Estadísticas), así que se pinta al instante y funciona sin conexión.
///
/// Es la **entrada** al dashboard de estadísticas que llega en la Fase 8, no
/// una versión reducida que haya que tirar después: toda la lógica de cálculo
/// vive en `weeklyHighlightsProvider`, y esto solo la dibuja.
///
/// En escritorio se despliega en dos columnas (artistas | canciones) con los
/// minutos de cabecera; en móvil se apila. Si no hay nada que contar (usuario
/// nuevo), no se muestra: una tarjeta en cero es ruido, no información.
class WeeklyHighlightsPanel extends ConsumerWidget {
  const WeeklyHighlightsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final highlights = ref.watch(weeklyHighlightsProvider).value;
    if (highlights == null || highlights.isEmpty) return const SizedBox.shrink();

    final isDesktop = MediaQuery.of(context).size.width >= 768;

    final artistsColumn = _MiniTopList(
      heading: 'Artistas',
      items: [
        for (final enriched in highlights.topArtists)
          _MiniItem(
            title: enriched.artist.name,
            subtitle: '${enriched.entry.minutes} min',
            imageUrl: enriched.artist.pictureUrl,
            isCircle: true,
            route: enriched.artist.id > 0 ? '/artist/${enriched.artist.id}' : null,
          ),
      ],
    );

    final tracksColumn = _MiniTopList(
      heading: 'Canciones',
      items: [
        for (final enriched in highlights.topTracks)
          _MiniItem(
            title: enriched.track.title,
            subtitle: enriched.track.artistName,
            imageUrl: enriched.track.coverUrl,
            isCircle: false,
            // Sin destino: una canción suelta no es una colección que abrir,
            // acá es un dato del resumen (regla de diseño de Inicio).
            route: null,
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/stats'),
          child: Padding(
            padding: EdgeInsets.all(isDesktop ? 20 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(AppIcons.broken(SolarIcons.Chart), color: AppTheme.accent, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Tu semana',
                        style: TextStyle(
                          color: AppTheme.primary,
                          fontSize: isDesktop ? 18 : 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      highlights.totalMinutes > 0 ? '${highlights.totalMinutes} min' : '< 1 min',
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary, size: 16),
                  ],
                ),
                if (highlights.topArtists.isNotEmpty || highlights.topTracks.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  if (isDesktop)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: artistsColumn),
                        const SizedBox(width: 24),
                        Expanded(child: tracksColumn),
                      ],
                    )
                  else ...[
                    artistsColumn,
                    if (highlights.topTracks.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      tracksColumn,
                    ],
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniItem {
  final String title;
  final String subtitle;
  final String imageUrl;
  final bool isCircle;
  final String? route;

  const _MiniItem({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.isCircle,
    this.route,
  });
}

class _MiniTopList extends StatelessWidget {
  final String heading;
  final List<_MiniItem> items;

  const _MiniTopList({required this.heading, required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading.toUpperCase(),
          style: const TextStyle(
            color: AppTheme.secondary,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < items.length; i++) _buildRow(context, i, items[i]),
      ],
    );
  }

  Widget _buildRow(BuildContext context, int index, _MiniItem item) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text(
              '${index + 1}',
              style: const TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(item.isCircle ? 999 : 6),
            child: SizedBox(
              width: 32,
              height: 32,
              child: item.imageUrl.isEmpty
                  ? Container(color: AppTheme.surfaceHover)
                  : CachedNetworkImage(imageUrl: item.imageUrl, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (item.subtitle.isNotEmpty)
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.secondary, fontSize: 11),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    if (item.route == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => context.push(item.route!),
      child: row,
    );
  }
}
