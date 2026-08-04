import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../../core/widgets/track_tile.dart';
import '../../player/player_models.dart';
import '../../player/player_providers.dart';

/// Pantalla de Búsqueda (SearchScreen calcada del mockup search.html / image5.png).
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;
  bool _isSearching = false;
  String _selectedFilter = 'Todo';

  final List<String> _filters = const ['Todo', 'Canciones', 'Artistas', 'Playlists', 'Álbumes', 'Podcasts'];

  final List<Map<String, dynamic>> _categories = const [
    {'name': 'Pop', 'color': AppTheme.genrePop},
    {'name': 'Hip-Hop', 'color': AppTheme.genreHipHop},
    {'name': 'Rock', 'color': AppTheme.genreRock},
    {'name': 'Electrónica', 'color': AppTheme.genreElectronic},
    {'name': 'Indie', 'color': Color(0xFF6D28D9)},
    {'name': 'Lofi & Chill', 'color': Color(0xFF0369A1)},
  ];

  final List<SyncoraTrack> _mockSearchResults = [
    SyncoraTrack(
      id: 'search_1',
      title: 'Los Angeles',
      artist: 'The Midnight',
      album: 'Los Angeles',
      duration: const Duration(seconds: 292),
      youtubeVideoId: 'dQw4w9WgXcQ',
      artUri: Uri.parse('https://images.unsplash.com/photo-1614613535308-eb5fbd3d2c17?q=80&w=300&auto=format&fit=crop'),
    ),
    SyncoraTrack(
      id: 'search_2',
      title: 'Neon Shadows',
      artist: 'The Midnight',
      album: 'Endless Summer',
      duration: const Duration(seconds: 236),
      youtubeVideoId: 'dvgZkm1xWPE',
      artUri: Uri.parse('https://images.unsplash.com/photo-1493225457124-a1a2a5f529a8?q=80&w=300&auto=format&fit=crop'),
    ),
  ];

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String text) {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    if (text.isEmpty) {
      setState(() {
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
    });

    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim();
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Search Header
          Padding(
            padding: EdgeInsets.fromLTRB(
              isDesktop ? 32 : 20,
              isDesktop ? 24 : 16,
              isDesktop ? 32 : 20,
              12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
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
                  onChanged: _onSearchChanged,
                  style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    hintText: '¿Qué quieres escuchar?',
                    hintStyle: TextStyle(color: AppTheme.secondary.withValues(alpha: 0.7), fontWeight: FontWeight.w500),
                    prefixIcon: const Icon(LucideIcons.search, color: AppTheme.secondary, size: 20),
                    suffixIcon: query.isNotEmpty
                        ? IconButton(
                            icon: const Icon(LucideIcons.x, color: AppTheme.secondary, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
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

          // Píldoras de Filtro
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20, vertical: 4),
            child: Row(
              children: _filters.map((filter) {
                final isSelected = _selectedFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(filter),
                    selected: isSelected,
                    onSelected: (val) {
                      if (val) setState(() => _selectedFilter = filter);
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
          ),

          const SizedBox(height: 16),

          // Contenido dinámico
          Expanded(
            child: _isSearching
                ? _buildSkeletonResults()
                : SingleChildScrollView(
                    padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Solo mostrar resultados cuando hay un texto ingresado
                        if (query.isNotEmpty) ...[
                          if (isDesktop)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: _buildTopResultCard(),
                                ),
                                const SizedBox(width: 24),
                                Expanded(
                                  flex: 6,
                                  child: _buildSongsListSection(),
                                ),
                              ],
                            )
                          else ...[
                            _buildTopResultCard(),
                            const SizedBox(height: 24),
                            _buildSongsListSection(),
                          ],
                          const SizedBox(height: 32),
                        ],

                        // Sección "Explorar todo" (Siempre visible al entrar a la pantalla)
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
                            return Container(
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
                            );
                          },
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Tarjeta "Mejor resultado" del artista principal
  Widget _buildTopResultCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Mejor resultado',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => context.push('/artist/a1'),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: AppTheme.surfaceShadow,
            ),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(50),
                      child: SizedBox(
                        width: 96,
                        height: 96,
                        child: CachedNetworkImage(
                          imageUrl: 'https://images.unsplash.com/photo-1549834125-82d3c48159a3?q=80&w=300&auto=format&fit=crop',
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => Container(
                            color: AppTheme.surfaceHover,
                            child: const Icon(LucideIcons.user, color: AppTheme.muted, size: 40),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'The Midnight',
                      style: TextStyle(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 24,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.background.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'ARTISTA',
                        style: TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.primary,
                      boxShadow: AppTheme.glowShadow,
                    ),
                    child: const Icon(LucideIcons.play, color: AppTheme.background, size: 24),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Lista de "Canciones" asociadas
  Widget _buildSongsListSection() {
    final currentTrack = ref.watch(currentTrackProvider);
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Canciones',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 16),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _mockSearchResults.length,
          itemBuilder: (ctx, i) {
            final track = _mockSearchResults[i];
            final isPlaying = currentTrack?.id == track.id;

            return TrackTile(
              track: track,
              isPlaying: isPlaying,
              onTap: () {
                controller.setQueue([track], startIndex: 0);
                controller.play();
              },
              onAddToQueue: () => controller.addToQueue(track),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSkeletonResults() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
