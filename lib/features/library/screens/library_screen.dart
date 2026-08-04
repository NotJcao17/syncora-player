import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';

/// Pantalla de Biblioteca del Usuario (LibraryScreen calcada de library.html mockup).
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _selectedFilter = 'Playlists';

  final List<String> _filters = const ['Playlists', 'Álbumes', 'Artistas', 'Descargados'];

  final List<Map<String, String>> _mockLibraryItems = const [
    {
      'id': 'liked',
      'title': 'Canciones que me gustan',
      'subtitle': 'Playlist • 142 canciones',
      'type': 'liked',
    },
    {
      'id': 'p1',
      'title': 'Neon Shadows',
      'subtitle': 'Playlist • Aether',
      'cover': 'https://images.unsplash.com/photo-1614613535308-eb5fbd3d2c17?q=80&w=300&auto=format&fit=crop',
      'type': 'playlist',
    },
    {
      'id': 'p2',
      'title': 'Deep Focus',
      'subtitle': 'Playlist • Syncora',
      'cover': 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?q=80&w=300&auto=format&fit=crop',
      'type': 'playlist',
    },
    {
      'id': 'a1',
      'title': 'Lorn',
      'subtitle': 'Artista',
      'cover': 'https://images.unsplash.com/photo-1549834125-82d3c48159a3?q=80&w=300&auto=format&fit=crop',
      'type': 'artist',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Tu Biblioteca + Search & Plus action buttons
          Padding(
            padding: EdgeInsets.fromLTRB(
              isDesktop ? 32 : 20,
              isDesktop ? 20 : 12,
              isDesktop ? 32 : 20,
              10,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    if (!isDesktop) ...[
                      GestureDetector(
                        onTap: () => context.push('/settings'),
                        child: ClipRRect(
                          borderRadius: const BorderRadius.all(Radius.circular(999)),
                          child: CachedNetworkImage(
                            imageUrl: 'https://i.pravatar.cc/150?img=11',
                            width: 32,
                            height: 32,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      'Tu Biblioteca',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.primary,
                        letterSpacing: -0.5,
                        shadows: AppTheme.textGlow,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Tooltip(
                      message: 'Buscar',
                      child: IconButton(
                        icon: const Icon(LucideIcons.search, color: AppTheme.primary, size: 20),
                        onPressed: () => context.push('/search'),
                      ),
                    ),
                    Tooltip(
                      message: 'Crear playlist',
                      child: IconButton(
                        icon: const Icon(LucideIcons.plus, color: AppTheme.primary, size: 22),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Crear nueva playlist')),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(color: AppTheme.surface, height: 1),
          const SizedBox(height: 12),

          // Píldoras de Filtro
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20, vertical: 2),
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelStyle: TextStyle(
                      color: isSelected ? AppTheme.background : AppTheme.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
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

          // Lista de elementos de biblioteca
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
              itemCount: _mockLibraryItems.length,
              itemBuilder: (ctx, i) {
                final item = _mockLibraryItems[i];
                final isLiked = item['type'] == 'liked';
                final isArtist = item['type'] == 'artist';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: InkWell(
                    onTap: () {
                      if (isArtist) {
                        context.push('/artist/${item['id']}');
                      } else {
                        context.push('/playlist/${item['id']}');
                      }
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          // Cover 64x64 Image / Gradient Heart / Artist Circle
                          ClipRRect(
                            borderRadius: BorderRadius.circular(isArtist ? 32 : 12),
                            child: SizedBox(
                              width: 64,
                              height: 64,
                              child: isLiked
                                  ? Container(
                                      decoration: const BoxDecoration(
                                        gradient: AppTheme.gradientLiked,
                                      ),
                                      child: const Icon(
                                        LucideIcons.heart,
                                        color: Colors.white,
                                        size: 28,
                                      ),
                                    )
                                  : CachedNetworkImage(
                                      imageUrl: item['cover']!,
                                      memCacheWidth: 300,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, _, _) => Container(
                                        color: AppTheme.surfaceHover,
                                        child: Icon(
                                          isArtist ? LucideIcons.user : LucideIcons.music,
                                          color: AppTheme.muted,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 16),

                          // Text detail
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item['title']!,
                                  style: const TextStyle(
                                    color: AppTheme.primary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  item['subtitle']!,
                                  style: const TextStyle(
                                    color: AppTheme.secondary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
