import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/playlist_card.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/apis/deezer_api.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/models/deezer/deezer_album.dart';
import '../../../data/models/deezer/deezer_artist.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../auth/local_mode_provider.dart';
import '../../player/player_providers.dart';
import '../ai_lyric_search/ai_lyric_search_sheet.dart';
import '../collaboration_search.dart';
import '../exact_track_search.dart';
import '../other_versions_search.dart';
import '../search_history_storage.dart';
import '../search_provider.dart';
import '../search_ranking.dart';

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

  // En desktop es una ventana central (Dialog) — nada de sheet arrastrable
  // desde abajo, eso solo tiene sentido como gesto táctil en móvil.
  void _openDeepSearchModal(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    if (isDesktop) {
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: AppTheme.background,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
          child: SizedBox(
            width: 640,
            height: 680,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: const _DeepSearchModalContent(),
            ),
          ),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.85,
        child: Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: const _DeepSearchModalContent(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final searchNotifier = ref.read(searchProvider.notifier);
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    // 7.I: la búsqueda por letra necesita el JWT del usuario -- se oculta
    // sin cuenta (D-24), no solo se deshabilita.
    final isLocalMode = ref.watch(localModeProvider);

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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
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

                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Tooltip(
                          message: searchState.popularOnly
                              ? 'Mostrando solo resultados populares'
                              : 'Mostrando todos los resultados',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => searchNotifier.setPopularOnly(!searchState.popularOnly),
                            child: Container(
                              width: 40,
                              height: 40,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: searchState.popularOnly ? AppTheme.primary : AppTheme.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: searchState.popularOnly
                                      ? AppTheme.primary
                                      : AppTheme.secondary.withValues(alpha: 0.4),
                                  width: 1.2,
                                ),
                              ),
                              child: Icon(
                                searchState.popularOnly
                                    ? AppIcons.bold(SolarIcons.Chart)
                                    : AppIcons.broken(SolarIcons.Chart),
                                size: 18,
                                color: searchState.popularOnly ? AppTheme.background : AppTheme.secondary,
                              ),
                            ),
                          ),
                        ),
                        if (!isLocalMode) ...[
                          const SizedBox(width: 8),
                          // Fase 7.F.4: buscar canción por fragmento de letra
                          // con IA -- mismo estilo compacto que el toggle
                          // "Popular" de al lado (D-14: ícono `StarsMinimalistic`
                          // consistente en los 4 puntos de entrada de IA).
                          Tooltip(
                            message: 'Buscar por letra con IA',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                FocusManager.instance.primaryFocus?.unfocus();
                                final isConnected = ref.read(isConnectedProvider).value ?? true;
                                if (!isConnected) {
                                  AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
                                  return;
                                }
                                showAiLyricSearchSheet(context, ref);
                              },
                              child: Container(
                                width: 40,
                                height: 40,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: AppTheme.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: AppTheme.secondary.withValues(alpha: 0.4),
                                    width: 1.2,
                                  ),
                                ),
                                child: Icon(
                                  AppIcons.broken(SolarIcons.StarsMinimalistic),
                                  size: 18,
                                  color: AppTheme.secondary,
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        // Botón para Búsqueda Profunda (Fase D): exacta artista+título
                        // (D3) y colaboraciones entre 2 artistas (D1) — para cuando el
                        // buscador normal no encuentra algo.
                        SizedBox(
                          height: 40,
                          child: OutlinedButton.icon(
                            onPressed: () => _openDeepSearchModal(context),
                            icon: Icon(AppIcons.bold(SolarIcons.Magnifer), size: 16, color: AppTheme.primary),
                            label: const Text(
                              'Búsqueda Profunda',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primary,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.5), width: 1.2),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
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
                        ? _buildEmptyQueryView(isDesktop)
                        : _buildSearchResults(searchState, isDesktop),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyQueryView(bool isDesktop) {
    final history = ref.watch(searchHistoryProvider);

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (history.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Búsquedas recientes',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: AppTheme.primary,
                        ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    ref.read(searchHistoryProvider.notifier).clearAll();
                  },
                  child: const Text(
                    'Borrar todo el historial',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppTheme.secondary, fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: history.map((term) {
                return InputChip(
                  avatar: Icon(AppIcons.broken(SolarIcons.Magnifer), size: 14, color: AppTheme.secondary),
                  label: Text(term, style: const TextStyle(color: AppTheme.primary, fontSize: 13)),
                  backgroundColor: AppTheme.surface,
                  deleteIcon: const Icon(Icons.close, size: 14, color: AppTheme.secondary),
                  onDeleted: () {
                    ref.read(searchHistoryProvider.notifier).removeQuery(term);
                  },
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    _searchController.text = term;
                    ref.read(searchProvider.notifier).setQuery(term);
                  },
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: const BorderSide(color: AppTheme.surfaceHover),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
          ],
          _buildExploreCategories(isDesktop),
        ],
      ),
    );
  }

  Widget _buildExploreCategories(bool isDesktop) {
    return Column(
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
                FocusManager.instance.primaryFocus?.unfocus();
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

    // Toggle "Popular": filtro en cliente, no dispara una nueva búsqueda.
    final displayedArtists =
        state.popularOnly ? result.artists.where(SearchRanking.isPopularArtist).toList() : result.artists;
    final displayedTracks =
        state.popularOnly ? result.tracks.where(SearchRanking.isPopularTrack).toList() : result.tracks;

    final hasContent = displayedArtists.isNotEmpty || displayedTracks.isNotEmpty || result.albums.isNotEmpty;
    if (!hasContent) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.broken(SolarIcons.Chart), size: 48, color: AppTheme.secondary),
            const SizedBox(height: 12),
            const Text(
              'Sin resultados populares para esta búsqueda',
              style: TextStyle(color: AppTheme.secondary, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.read(searchProvider.notifier).setPopularOnly(false),
              child: const Text('Mostrar todos los resultados'),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Artistas destacados si existen
          if (displayedArtists.isNotEmpty) ...[
            _buildArtistSection(displayedArtists, isDesktop, state.searchType),
            const SizedBox(height: 24),
          ],

          // Lista de canciones
          if (displayedTracks.isNotEmpty) ...[
            _buildSongsSection(displayedTracks),
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

  Widget _buildArtistSection(List<DeezerArtist> artists, bool isDesktop, DeezerSearchType searchType) {
    // "Todo" comparte espacio con canciones y álbumes, se queda acotado a 5.
    // La pestaña "Artistas" dedicada puede mostrar bastantes más — ya viene
    // filtrada por relevancia (y, si el toggle "Popular" está activo, por
    // popularidad también), así que un tope más alto no implica mostrar ruido.
    final cap = searchType == DeezerSearchType.all ? 5 : 40;
    final displayArtists = artists.length > cap ? artists.sublist(0, cap) : artists;

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
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  final q = _searchController.text.trim();
                  if (q.isNotEmpty) ref.read(searchHistoryProvider.notifier).addQuery(q);
                  context.push('/artist/${artist.id}');
                },
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
                FocusManager.instance.primaryFocus?.unfocus();
                final q = _searchController.text.trim();
                if (q.isNotEmpty) ref.read(searchHistoryProvider.notifier).addQuery(q);
                controller.setQueue(syncoraTracks, startIndex: i);
              },
              onAddToQueue: () {
                final q = _searchController.text.trim();
                if (q.isNotEmpty) ref.read(searchHistoryProvider.notifier).addQuery(q);
                controller.addToQueue(track);
              },
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
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    final q = _searchController.text.trim();
                    if (q.isNotEmpty) ref.read(searchHistoryProvider.notifier).addQuery(q);
                    context.push('/album/${album.id}');
                  },
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

/// Contenido del modal de Búsqueda Profunda (Fase D): pestañas "Exacta" (D3)
/// y "Colaboración" (D1). D2 no es una pestaña propia — es el botón "Buscar
/// más a fondo" que aparece dentro de cada pestaña cuando esta no encuentra
/// nada o muy poco (ver docs/plan_buscador_importacion_matcher.md, Fase D).
///
/// Solo el contenido: el tamaño/contenedor (sheet arrastrable en móvil,
/// diálogo centrado en desktop) lo decide `_openDeepSearchModal`.
class _DeepSearchModalContent extends StatefulWidget {
  const _DeepSearchModalContent();

  @override
  State<_DeepSearchModalContent> createState() => _DeepSearchModalContentState();
}

class _DeepSearchModalContentState extends State<_DeepSearchModalContent> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(AppIcons.bold(SolarIcons.Magnifer), color: AppTheme.primary, size: 22),
                const SizedBox(width: 8),
                const Text(
                  'Búsqueda Profunda',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary,
                  ),
                ),
              ],
            ),
            IconButton(
              icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Para cuando el buscador normal no encuentra algo: coincidencia exacta o colaboraciones puntuales.',
          style: TextStyle(color: AppTheme.secondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: AppTheme.surface, borderRadius: BorderRadius.circular(14)),
          child: TabBar(
            controller: _tabController,
            indicator: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(10)),
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            labelColor: AppTheme.background,
            unselectedLabelColor: AppTheme.secondary,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            tabs: const [Tab(text: 'Exacta'), Tab(text: 'Colaboración')],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              _ExactSearchTab(),
              _CollaborationSearchTab(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Botón compartido "Buscar más a fondo" (D2, escape manual desde D1/D3
/// cuando no hay resultados o hay muy pocos).
class _SearchMoreButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onPressed;

  const _SearchMoreButton({
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: isLoading ? null : onPressed,
      icon: isLoading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary),
            )
          : Icon(AppIcons.broken(SolarIcons.Magnifer), size: 16, color: AppTheme.primary),
      label: Text(
        isLoading ? 'Buscando en la discografía...' : 'Buscar más a fondo en la discografía',
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Pestaña "Exacta" (D3): dos campos, artista + título, cascada
/// `artist:"X" track:"Y"` -> texto plano -> solo título (mismo módulo
/// compartido con la importación CSV de Fase B). A diferencia del
/// importador, no auto-elige: rankea con [SearchRanking] y deja que el
/// usuario elija de la lista.
class _ExactSearchTab extends ConsumerStatefulWidget {
  const _ExactSearchTab();

  @override
  ConsumerState<_ExactSearchTab> createState() => _ExactSearchTabState();
}

class _ExactSearchTabState extends ConsumerState<_ExactSearchTab> {
  final TextEditingController _artistController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();

  bool _isSearching = false;
  bool _isSearchingMore = false;
  bool _searched = false;
  String? _error;
  List<DeezerTrack> _results = [];

  @override
  void dispose() {
    _artistController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final artist = _artistController.text.trim();
    final title = _titleController.text.trim();
    if (artist.isEmpty || title.isEmpty) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _isSearching = true;
      _searched = true;
      _error = null;
      _results = [];
    });

    final deezerApi = ref.read(deezerApiProvider);
    try {
      final tracks = await ExactTrackSearch.cascadeSearch(
        deezerApi,
        artist: artist,
        title: title,
        accept: (list) => list.isNotEmpty,
      );
      if (!mounted) return;
      setState(() {
        _isSearching = false;
        _results = SearchRanking.rankTracks(tracks, '$artist $title');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
        _error = 'Error al conectar con Deezer. Verifica tu conexión.';
      });
    }
  }

  // D2 (entrada 2, fallback): crawl acotado de la discografía del artista
  // buscando el mismo título base, para el hueco real de índice de Deezer
  // que ni la cascada exacta puede resolver (ver caso "Guess" en el plan).
  Future<void> _searchMore() async {
    final artist = _artistController.text.trim();
    final title = _titleController.text.trim();
    if (artist.isEmpty || title.isEmpty) return;

    setState(() => _isSearchingMore = true);
    final deezerApi = ref.read(deezerApiProvider);
    try {
      final artistRes = await deezerApi.search(artist, type: DeezerSearchType.artist);
      if (artistRes.artists.isEmpty) {
        if (!mounted) return;
        setState(() => _isSearchingMore = false);
        if (context.mounted) AppToast.show(context, message: 'No se encontró al artista "$artist".');
        return;
      }
      final artistMatch = artistRes.artists.first;
      final more = await OtherVersionsSearch.searchByTitle(deezerApi, artistId: artistMatch.id, title: title);
      if (!mounted) return;

      final seenIds = _results.map((t) => t.id).toSet();
      final merged = [..._results, ...more.where((t) => seenIds.add(t.id))];
      setState(() {
        _isSearchingMore = false;
        _results = SearchRanking.rankTracks(merged, '$artist $title');
      });
      if (context.mounted && more.isEmpty) {
        AppToast.show(context, message: 'No se encontraron más versiones en la discografía de $artist.');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSearchingMore = false);
      if (context.mounted) AppToast.show(context, message: 'Error al buscar más a fondo.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // TabBarView clipea a sus propios bordes (es un PageView por dentro):
        // sin este margen, la etiqueta flotante del primer campo (que asoma
        // por encima del borde del TextField) queda cortada contra el borde
        // superior de la pestaña.
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _artistController,
                style: const TextStyle(color: AppTheme.primary, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Artista',
                  labelStyle: const TextStyle(color: AppTheme.secondary),
                  filled: true,
                  fillColor: AppTheme.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _titleController,
                style: const TextStyle(color: AppTheme.primary, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Título',
                  labelStyle: const TextStyle(color: AppTheme.secondary),
                  filled: true,
                  fillColor: AppTheme.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _isSearching ? null : _search,
            icon: _isSearching
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.background),
                  )
                : Icon(AppIcons.broken(SolarIcons.Magnifer), size: 20),
            label: Text(_isSearching ? 'Buscando...' : 'Buscar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: AppTheme.background,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (!_searched) {
      return const Center(
        child: Text(
          'Escribe artista y título para buscar la coincidencia exacta.',
          style: TextStyle(color: AppTheme.secondary),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: AppTheme.secondary)));
    }
    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No se encontraron resultados exactos.',
              style: TextStyle(color: AppTheme.secondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            _SearchMoreButton(isLoading: _isSearchingMore, onPressed: _searchMore),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (ctx, i) {
              final track = _results[i].toSyncoraTrack();
              return TrackTile(
                track: track,
                onTap: () {
                  final syncoraTracks = _results.map((t) => t.toSyncoraTrack()).toList();
                  ref.read(syncoraPlayerControllerProvider.notifier).setQueue(syncoraTracks, startIndex: i);
                  Navigator.pop(context);
                },
                onAddToQueue: () => ref.read(syncoraPlayerControllerProvider.notifier).addToQueue(track),
              );
            },
          ),
        ),
        if (_results.length < 3) ...[
          const SizedBox(height: 8),
          Center(child: _SearchMoreButton(isLoading: _isSearchingMore, onPressed: _searchMore)),
        ],
      ],
    );
  }
}

/// Pestaña "Colaboración" (D1): dos artistas, 5 peticiones en 2 tandas
/// paralelas (resolver ambos artistas, luego texto plano + top tracks de
/// cada uno), filtrando por `contributors` cruzando ambos nombres.
class _CollaborationSearchTab extends ConsumerStatefulWidget {
  const _CollaborationSearchTab();

  @override
  ConsumerState<_CollaborationSearchTab> createState() => _CollaborationSearchTabState();
}

class _CollaborationSearchTabState extends ConsumerState<_CollaborationSearchTab> {
  final TextEditingController _artist1Controller = TextEditingController();
  final TextEditingController _artist2Controller = TextEditingController();

  bool _isSearching = false;
  bool _isSearchingMore = false;
  bool _searched = false;
  String? _error;
  DeezerArtist? _artist1;
  DeezerArtist? _artist2;
  List<DeezerTrack> _results = [];

  @override
  void dispose() {
    _artist1Controller.dispose();
    _artist2Controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final a1 = _artist1Controller.text.trim();
    final a2 = _artist2Controller.text.trim();
    if (a1.isEmpty || a2.isEmpty) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _isSearching = true;
      _searched = true;
      _error = null;
      _results = [];
      _artist1 = null;
      _artist2 = null;
    });

    final deezerApi = ref.read(deezerApiProvider);
    try {
      final result = await CollaborationSearch.search(deezerApi, artist1: a1, artist2: a2);
      if (!mounted) return;
      if (result.artist1 == null || result.artist2 == null) {
        setState(() {
          _isSearching = false;
          _error = 'No se encontró a "${result.artist1 == null ? a1 : a2}".';
        });
        return;
      }
      setState(() {
        _isSearching = false;
        _artist1 = result.artist1;
        _artist2 = result.artist2;
        _results = result.tracks;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
        _error = 'Error al conectar con Deezer. Verifica tu conexión.';
      });
    }
  }

  // D2 (entrada 2, fallback): crawl acotado de la discografía de artist1
  // buscando tracks que también mencionen a artist2 — mismo crawl que la
  // pestaña "Exacta", pero filtrando por el OTRO artista en vez de por
  // título (no hay un título único cuando se busca una colaboración).
  Future<void> _searchMore() async {
    final artist1 = _artist1;
    final artist2 = _artist2;
    if (artist1 == null || artist2 == null) return;

    setState(() => _isSearchingMore = true);
    final deezerApi = ref.read(deezerApiProvider);
    try {
      final more = await OtherVersionsSearch.search(
        deezerApi,
        artistId: artist1.id,
        matches: (t) => CollaborationSearch.trackHasArtist(t, artistName: artist2.name, artistId: artist2.id),
      );
      if (!mounted) return;

      final seenIds = _results.map((t) => t.id).toSet();
      final merged = [..._results, ...more.where((t) => seenIds.add(t.id))];
      setState(() {
        _isSearchingMore = false;
        _results = SearchRanking.rankTracks(merged, '${artist1.name} ${artist2.name}');
      });
      if (context.mounted && more.isEmpty) {
        AppToast.show(context, message: 'No se encontraron más colaboraciones en la discografía de ${artist1.name}.');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSearchingMore = false);
      if (context.mounted) AppToast.show(context, message: 'Error al buscar más a fondo.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Ver comentario equivalente en _ExactSearchTabState.build(): margen
        // para que la etiqueta flotante del primer campo no quede cortada
        // contra el borde superior de la pestaña (TabBarView clipea).
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _artist1Controller,
                style: const TextStyle(color: AppTheme.primary, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Artista 1',
                  labelStyle: const TextStyle(color: AppTheme.secondary),
                  filled: true,
                  fillColor: AppTheme.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _artist2Controller,
                style: const TextStyle(color: AppTheme.primary, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Artista 2',
                  labelStyle: const TextStyle(color: AppTheme.secondary),
                  filled: true,
                  fillColor: AppTheme.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _isSearching ? null : _search,
            icon: _isSearching
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.background),
                  )
                : Icon(AppIcons.broken(SolarIcons.Magnifer), size: 20),
            label: Text(_isSearching ? 'Buscando...' : 'Buscar colaboración'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: AppTheme.background,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (!_searched) {
      return const Center(
        child: Text(
          'Escribe los dos artistas para buscar canciones donde colaboran.',
          style: TextStyle(color: AppTheme.secondary),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: AppTheme.secondary)));
    }

    final canSearchMore = _artist1 != null && _artist2 != null;

    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No se encontraron colaboraciones.',
              style: TextStyle(color: AppTheme.secondary),
              textAlign: TextAlign.center,
            ),
            if (canSearchMore) ...[
              const SizedBox(height: 12),
              _SearchMoreButton(isLoading: _isSearchingMore, onPressed: _searchMore),
            ],
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (ctx, i) {
              final track = _results[i].toSyncoraTrack();
              return TrackTile(
                track: track,
                onTap: () {
                  final syncoraTracks = _results.map((t) => t.toSyncoraTrack()).toList();
                  ref.read(syncoraPlayerControllerProvider.notifier).setQueue(syncoraTracks, startIndex: i);
                  Navigator.pop(context);
                },
                onAddToQueue: () => ref.read(syncoraPlayerControllerProvider.notifier).addToQueue(track),
              );
            },
          ),
        ),
        if (canSearchMore && _results.length < 3) ...[
          const SizedBox(height: 8),
          Center(child: _SearchMoreButton(isLoading: _isSearchingMore, onPressed: _searchMore)),
        ],
      ],
    );
  }
}
