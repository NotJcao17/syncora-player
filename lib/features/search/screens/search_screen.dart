import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/playlist_card.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/apis/deezer_api.dart';
import '../../../data/models/deezer/deezer_album.dart';
import '../../../data/models/deezer/deezer_artist.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../player/player_providers.dart';
import '../search_provider.dart';

/// Pantalla de Búsqueda conectada a Deezer real con Debounce 500ms y filtros.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();

  final List<Map<String, dynamic>> _filters = const [
    {'name': 'Todo', 'type': DeezerSearchType.all},
    {'name': 'Canciones', 'type': DeezerSearchType.track},
    {'name': 'Artistas', 'type': DeezerSearchType.artist},
    {'name': 'Álbumes', 'type': DeezerSearchType.album},
  ];

  final List<Map<String, dynamic>> _categories = const [
    {'name': 'Pop', 'color': AppTheme.genrePop},
    {'name': 'Hip-Hop', 'color': AppTheme.genreHipHop},
    {'name': 'Rock', 'color': AppTheme.genreRock},
    {'name': 'Electrónica', 'color': AppTheme.genreElectronic},
    {'name': 'Indie', 'color': Color(0xFF6D28D9)},
    {'name': 'Lofi & Chill', 'color': Color(0xFF0369A1)},
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final searchNotifier = ref.read(searchProvider.notifier);
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header de Búsqueda
          Padding(
            padding: EdgeInsets.fromLTRB(
              isDesktop ? 32 : 12,
              isDesktop ? 24 : 16,
              isDesktop ? 32 : 12,
              12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Buscar',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.primary,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _searchController,
                  onChanged: (val) => searchNotifier.setQuery(val),
                  style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    hintText: '¿Qué quieres escuchar?',
                    hintStyle: TextStyle(
                      color: AppTheme.secondary.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w500,
                    ),
                    prefixIcon: Icon(AppIcons.broken(SolarIcons.Magnifer), color: AppTheme.secondary, size: 20),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              searchNotifier.setQuery('');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppTheme.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppTheme.primary, width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Filtros de Búsqueda (Dropdown en Móvil, Chips en Desktop)
          if (_searchController.text.trim().isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 12, vertical: 4),
              child: isDesktop
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _filters.map((filter) {
                          final filterType = filter['type'] as DeezerSearchType;
                          final isSelected = searchState.searchType == filterType;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: ChoiceChip(
                              label: Text(filter['name'] as String),
                              selected: isSelected,
                              onSelected: (val) {
                                if (val) searchNotifier.setSearchType(filterType);
                              },
                              selectedColor: AppTheme.primary,
                              backgroundColor: AppTheme.surface,
                              labelStyle: TextStyle(
                                color: isSelected ? AppTheme.background : AppTheme.primary,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                              shape: StadiumBorder(
                                side: BorderSide(
                                  color: isSelected ? AppTheme.primary : AppTheme.surfaceHover,
                                ),
                              ),
                              showCheckmark: false,
                            ),
                          );
                        }).toList(),
                      ),
                    )
                  : Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.surfaceHover),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<DeezerSearchType>(
                          value: searchState.searchType,
                          isExpanded: true,
                          isDense: true,
                          dropdownColor: AppTheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          icon: Icon(AppIcons.broken(SolarIcons.AltArrowDown), color: AppTheme.primary, size: 20),
                          items: _filters.map((filter) {
                            return DropdownMenuItem<DeezerSearchType>(
                              value: filter['type'] as DeezerSearchType,
                              child: Text(
                                filter['name'] as String,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppTheme.primary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) searchNotifier.setSearchType(val);
                          },
                        ),
                      ),
                    ),
            ),

          const SizedBox(height: 16),

          // Cuerpo dinámico
          Expanded(
            child: searchState.isLoading
                ? _buildSkeletonResults()
                : searchState.errorMessage != null
                    ? ErrorStateWidget(
                        message: searchState.errorMessage!,
                        onRetry: () => searchNotifier.retry(),
                      )
                    : _searchController.text.trim().isEmpty
                        ? _buildExploreCategories(isDesktop)
                        : _buildSearchResults(searchState, isDesktop),
          ),
        ],
      ),
    );
  }

  Widget _buildExploreCategories(bool isDesktop) {
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Explorar todo',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: AppTheme.primary,
                ),
          ),
          const SizedBox(height: 16),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: isDesktop ? 5 : 2,
              childAspectRatio: 1.6,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: _categories.length,
            itemBuilder: (ctx, i) {
              final cat = _categories[i];
              return InkWell(
                onTap: () {
                  _searchController.text = cat['name'] as String;
                  ref.read(searchProvider.notifier).setQuery(cat['name'] as String);
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cat['color'] as Color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    cat['name'] as String,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSearchResults(SearchState state, bool isDesktop) {
    final result = state.result;

    if (result.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.broken(SolarIcons.Magnifer), size: 48, color: AppTheme.secondary),
            const SizedBox(height: 12),
            const Text(
              'No se encontraron resultados',
              style: TextStyle(color: AppTheme.secondary, fontSize: 16),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Artistas destacados si existen
          if (result.artists.isNotEmpty) ...[
            _buildArtistSection(result.artists, isDesktop),
            const SizedBox(height: 24),
          ],

          // Lista de canciones
          if (result.tracks.isNotEmpty) ...[
            _buildSongsSection(result.tracks),
            const SizedBox(height: 24),
          ],

          // Álbumes
          if (result.albums.isNotEmpty) ...[
            _buildAlbumsSection(result.albums, isDesktop),
            const SizedBox(height: 24),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildArtistSection(List<DeezerArtist> artists, bool isDesktop) {
    final displayArtists = artists.length > 5 ? artists.sublist(0, 5) : artists;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Artistas',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: displayArtists.length,
          itemBuilder: (ctx, i) {
            final artist = displayArtists[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: GestureDetector(
                onTap: () => context.push('/artist/${artist.id}'),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: AppTheme.surfaceShadow,
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(32),
                        child: SizedBox(
                          width: 56,
                          height: 56,
                          child: CachedNetworkImage(
                            imageUrl: artist.pictureUrl,
                            memCacheWidth: 300,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => Container(
                              color: AppTheme.surfaceHover,
                              child: Icon(AppIcons.broken(SolarIcons.User), color: AppTheme.muted, size: 28),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              artist.name,
                              style: const TextStyle(
                                color: AppTheme.primary,
                                fontWeight: FontWeight.bold,
                                fontSize: 17,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'ARTISTA',
                              style: TextStyle(
                                color: AppTheme.secondary,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSongsSection(List<DeezerTrack> tracks) {
    final currentTrack = ref.watch(currentTrackProvider);
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final syncoraTracks = tracks.map((t) => t.toSyncoraTrack()).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Canciones',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: tracks.length,
          itemBuilder: (ctx, i) {
            final track = syncoraTracks[i];
            final isPlaying = currentTrack?.id == track.id;

            return TrackTile(
              track: track,
              isPlaying: isPlaying,
              onTap: () {
                controller.setQueue(syncoraTracks, startIndex: i);
                controller.play();
              },
              onAddToQueue: () => controller.addToQueue(track),
            );
          },
        ),
      ],
    );
  }

  Widget _buildAlbumsSection(List<DeezerAlbum> albums, bool isDesktop) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Álbumes',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: albums.length,
            separatorBuilder: (ctx, index) => const SizedBox(width: 16),
            itemBuilder: (ctx, i) {
              final album = albums[i];
              return SizedBox(
                width: isDesktop ? 180 : 140,
                child: PlaylistCard(
                  title: album.title,
                  subtitle: album.artistName,
                  coverUrl: album.coverUrl,
                  onTap: () => context.push('/album/${album.id}'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSkeletonResults() {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    return ListView.separated(
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 12, vertical: 8),
      itemCount: 6,
      separatorBuilder: (ctx, index) => const SizedBox(height: 12),
      itemBuilder: (ctx, index) => const Row(
        children: [
          SkeletonBox(width: 48, height: 48, borderRadius: 6),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(width: 180, height: 16, borderRadius: 4),
                SizedBox(height: 6),
                SkeletonBox(width: 120, height: 12, borderRadius: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
