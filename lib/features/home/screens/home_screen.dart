import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/playlist_card.dart';
import '../../../core/widgets/skeleton_box.dart';

/// Pantalla Principal (HomeScreen calcada del mockup index.html / image4.png).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    });
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Buenos días';
    if (hour < 18) return 'Buenas tardes';
    return 'Buenas noches';
  }

  // Mocks de prueba calcados del mockup HTML index.html
  final List<Map<String, String>> _mockMadeForYou = const [
    {
      'id': 'p1',
      'title': 'Synthwave',
      'subtitle': 'The Midnight, Kavinsky, FM-84',
      'cover': 'https://images.unsplash.com/photo-1514525253161-7a46d19cd819?q=80&w=300&auto=format&fit=crop',
    },
    {
      'id': 'p2',
      'title': 'Chill Vibes',
      'subtitle': 'Lofi, Ambient, Study',
      'cover': 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?q=80&w=300&auto=format&fit=crop',
    },
    {
      'id': 'p3',
      'title': 'Focus 2026',
      'subtitle': 'Deep beats for coding',
      'cover': 'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?q=80&w=300&auto=format&fit=crop',
    },
  ];

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return ErrorStateWidget(
        message: 'No se pudieron cargar los datos de Inicio',
        onRetry: () {
          setState(() {
            _hasError = false;
            _isLoading = true;
          });
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) setState(() => _isLoading = false);
          });
        },
      );
    }

    final isDesktop = MediaQuery.of(context).size.width >= 768;

    return SafeArea(
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // Header Top Bar (Avatar en móvil + Saludo "Buenas noches" + Iconos con Tooltip)
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: isDesktop ? 32 : 20,
              vertical: isDesktop ? 24 : 16,
            ),
            sliver: SliverToBoxAdapter(
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
                              width: 38,
                              height: 38,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Text(
                        _getGreeting(),
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: AppTheme.primary,
                              letterSpacing: -0.5,
                            ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Tooltip(
                        message: 'Notificaciones',
                        child: IconButton(
                          icon: const Icon(LucideIcons.bell, color: AppTheme.primary, size: 22),
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Notificaciones próximamente')),
                            );
                          },
                        ),
                      ),
                      Tooltip(
                        message: 'Configuración',
                        child: IconButton(
                          icon: const Icon(LucideIcons.settings, color: AppTheme.primary, size: 22),
                          onPressed: () => context.push('/settings'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Sección 1: Reproducidos recientemente (Cuadrícula 2x4 tipo Spotify justo arriba)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverToBoxAdapter(
              child: _isLoading
                  ? const SkeletonBox(height: 120, borderRadius: 12)
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final crossCount = constraints.maxWidth > 700 ? 4 : 2;
                        final items = [
                          {
                            'title': 'Tus me gusta',
                            'cover': '',
                            'isLiked': true,
                            'route': '/library',
                          },
                          {
                            'title': 'Synthwave Mix',
                            'cover': 'https://images.unsplash.com/photo-1514525253161-7a46d19cd819?q=80&w=200&auto=format&fit=crop',
                            'route': '/playlist/p1',
                          },
                          {
                            'title': 'Chill Vibes',
                            'cover': 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?q=80&w=200&auto=format&fit=crop',
                            'route': '/playlist/p2',
                          },
                          {
                            'title': 'Focus 2026',
                            'cover': 'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?q=80&w=200&auto=format&fit=crop',
                            'route': '/playlist/p3',
                          },
                          {
                            'title': 'Los Angeles',
                            'cover': 'https://images.unsplash.com/photo-1614613535308-eb5fbd3d2c17?q=80&w=200&auto=format&fit=crop',
                            'route': '/album/album_1',
                          },
                          {
                            'title': 'Sunset Mix',
                            'cover': 'https://images.unsplash.com/photo-1493225457124-a1a2a5f529a8?q=80&w=200&auto=format&fit=crop',
                            'route': '/playlist/p1',
                          },
                        ];

                        return GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossCount,
                            mainAxisExtent: 56,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                          itemCount: items.length,
                          itemBuilder: (ctx, i) {
                            final item = items[i];
                            final isLiked = item['isLiked'] == true;

                            return InkWell(
                              onTap: () => context.push(item['route'] as String),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppTheme.surface,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                                      child: SizedBox(
                                        width: 56,
                                        height: 56,
                                        child: isLiked
                                            ? Container(
                                                decoration: const BoxDecoration(
                                                  gradient: AppTheme.gradientLiked,
                                                ),
                                                child: const Icon(LucideIcons.heart, color: Colors.white, size: 24, fill: 1.0),
                                              )
                                            : CachedNetworkImage(
                                                imageUrl: item['cover'] as String,
                                                fit: BoxFit.cover,
                                                errorWidget: (_, _, _) => Container(color: AppTheme.surfaceHover),
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        item['title'] as String,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppTheme.primary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),

          // Sección 2: Bento Grid (Destacados)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverToBoxAdapter(
              child: _isLoading
                  ? const Row(
                      children: [
                        Flexible(flex: 2, child: SkeletonBox(height: 240, borderRadius: 16)),
                        SizedBox(width: 16),
                        Flexible(child: SkeletonBox(height: 240, borderRadius: 16)),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (ctx, constraints) {
                        final wide = constraints.maxWidth > 600;
                        return Column(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Tarjeta Grande Release
                                Expanded(
                                  flex: wide ? 2 : 1,
                                  child: GestureDetector(
                                    onTap: () => context.push('/playlist/p_release'),
                                    child: Container(
                                      height: wide ? 260 : 200,
                                      decoration: BoxDecoration(
                                        color: AppTheme.surface,
                                        borderRadius: BorderRadius.circular(16),
                                        boxShadow: AppTheme.surfaceShadow,
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            CachedNetworkImage(
                                              imageUrl: 'https://images.unsplash.com/photo-1614613535308-eb5fbd3d2c17?q=80&w=600&auto=format&fit=crop',
                                              fit: BoxFit.cover,
                                              errorWidget: (_, _, _) => Container(color: AppTheme.surfaceHover),
                                            ),
                                            Positioned.fill(
                                              child: DecoratedBox(
                                                decoration: BoxDecoration(
                                                  gradient: LinearGradient(
                                                    begin: Alignment.topCenter,
                                                    end: Alignment.bottomCenter,
                                                    colors: [
                                                      Colors.transparent,
                                                      Colors.black.withValues(alpha: 0.4),
                                                      Colors.black.withValues(alpha: 0.85),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              left: 16,
                                              right: 16,
                                              bottom: 16,
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                    decoration: BoxDecoration(
                                                      color: AppTheme.primary.withValues(alpha: 0.2),
                                                      borderRadius: BorderRadius.circular(4),
                                                      border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4), width: 1),
                                                    ),
                                                    child: const Text(
                                                      'NUEVO LANZAMIENTO',
                                                      style: TextStyle(
                                                        color: AppTheme.primary,
                                                        fontSize: 10,
                                                        fontWeight: FontWeight.bold,
                                                        letterSpacing: 1.2,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  const Text(
                                                    'Los Angeles',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 22,
                                                      fontWeight: FontWeight.w900,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  const Text(
                                                    'The Midnight',
                                                    style: TextStyle(
                                                      color: AppTheme.secondary,
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w500,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (wide) ...[
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: PlaylistCard(
                                      title: 'Sunset Mix',
                                      subtitle: 'Daily Mix 1',
                                      coverUrl: 'https://images.unsplash.com/photo-1493225457124-a1a2a5f529a8?q=80&w=300&auto=format&fit=crop',
                                      onTap: () => context.push('/playlist/p1'),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: PlaylistCard(
                                      title: 'Discover',
                                      subtitle: 'Weekly',
                                      coverUrl: 'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?q=80&w=300&auto=format&fit=crop',
                                      onTap: () => context.push('/playlist/p2'),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 32)),

          // Sección 3: Made for you (Hecho para ti - Tarjetas limpia con texto abajo)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hecho para ti',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: AppTheme.primary,
                        ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: isDesktop ? 240 : 200,
                    child: _isLoading
                        ? ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: 3,
                            separatorBuilder: (ctx, index) => const SizedBox(width: 16),
                            itemBuilder: (ctx, index) => SkeletonBox(
                              width: isDesktop ? 180 : 140,
                              height: 200,
                              borderRadius: 16,
                            ),
                          )
                        : ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _mockMadeForYou.length,
                            separatorBuilder: (ctx, index) => const SizedBox(width: 16),
                            itemBuilder: (ctx, i) {
                              final item = _mockMadeForYou[i];
                              return SizedBox(
                                width: isDesktop ? 180 : 140,
                                child: PlaylistCard(
                                  title: item['title']!,
                                  subtitle: item['subtitle']!,
                                  coverUrl: item['cover'],
                                  onTap: () => context.push('/playlist/${item['id']}'),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}
