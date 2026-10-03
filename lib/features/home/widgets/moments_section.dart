import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/cache/api_cache.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/startup_retry.dart';
import '../../../core/widgets/playlist_card.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/models/deezer/deezer_playlist.dart';
import '../screens/home_screen.dart' show HomeCardRowSkeleton;
import 'home_sections.dart';

/// Momentos de "Para cada momento" (ronda 5): etiqueta visible y búsqueda en
/// `/search/playlist`. Las búsquedas en español traen sobre todo playlists de
/// los editores de Deezer para Latinoamérica.
const List<(String, String)> kHomeMoments = [
  ('Fiesta', 'fiesta'),
  ('Entrenar', 'entrenamiento'),
  ('Relajarse', 'chill'),
  ('Concentrarse', 'concentración'),
  ('Romántica', 'romántica'),
  ('De viaje', 'viaje'),
  ('Dormir', 'dormir'),
];

/// Playlists ya hechas de Deezer para un momento, cacheadas en disco con el
/// mismo TTL que las editoriales.
final momentPlaylistsProvider = FutureProvider.family<List<DeezerPlaylist>, String>((ref, query) async {
  final api = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<List<DeezerPlaylist>>(
    key: 'moment_playlists_$query',
    ttl: CacheTtl.charts,
    fetcher: () => retryOnNetworkError(() => api.searchPlaylists(query, limit: 25)),
    encode: (list) => list.map((p) => p.toJson()).toList(),
    decode: (json) => json is List
        ? json.whereType<Map>().map((item) => DeezerPlaylist.fromJson(Map<String, dynamic>.from(item))).toList()
        : <DeezerPlaylist>[],
  );
});

/// "Para cada momento" en Inicio (ronda 5): más playlists de Deezer además de
/// las editoriales, elegidas por ocasión con una fila de pastillas.
class HomeMomentsSection extends ConsumerStatefulWidget {
  const HomeMomentsSection({super.key, required this.isDesktop, required this.padding});

  final bool isDesktop;
  final double padding;

  @override
  ConsumerState<HomeMomentsSection> createState() => _HomeMomentsSectionState();
}

class _HomeMomentsSectionState extends ConsumerState<HomeMomentsSection> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final query = kHomeMoments[_selected].$2;
    final async = ref.watch(momentPlaylistsProvider(query));
    final playlists = async.value ?? const <DeezerPlaylist>[];

    return HomeSection(
      title: 'Para cada momento',
      subtitle: 'Playlists ya hechas de Deezer',
      isDesktop: widget.isDesktop,
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: widget.padding),
              itemCount: kHomeMoments.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final selected = i == _selected;
                return Material(
                  color: selected ? AppTheme.primary : AppTheme.surfaceHover,
                  shape: const StadiumBorder(),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => setState(() => _selected = i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        kHomeMoments[i].$1,
                        style: TextStyle(
                          color: selected ? AppTheme.background : AppTheme.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          if (async.isLoading && playlists.isEmpty)
            HomeCardRowSkeleton(isDesktop: widget.isDesktop, padding: widget.padding)
          else if (playlists.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.padding, vertical: 24),
              child: const Text(
                'No encontramos playlists para este momento ahora mismo.',
                style: TextStyle(color: AppTheme.secondary, fontSize: 13),
              ),
            )
          else
            HomeCardRow(
              isDesktop: widget.isDesktop,
              padding: widget.padding,
              itemCount: playlists.length,
              itemBuilder: (i) {
                final playlist = playlists[i];
                return PlaylistCard(
                  title: playlist.title,
                  subtitle: '${playlist.nbTracks} canciones • ${playlist.userName}',
                  coverUrl: playlist.pictureUrl,
                  onTap: () => context.push('/deezer-playlist/${playlist.id}'),
                );
              },
            ),
        ],
      ),
    );
  }
}
