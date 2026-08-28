import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import '../../auth/auth_provider.dart';
import '../../auth/local_mode_provider.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/playlist_card.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../../core/widgets/track_tile.dart';
import '../../player/player_providers.dart';
import '../../stats/stats_providers.dart';
import '../home_providers.dart';

/// Pantalla Principal conectada a Deezer API real y datos personalizados del usuario.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  String _getGreeting() {
    final mexicoNow = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    final hour = mexicoNow.hour;
    if (hour >= 5 && hour < 12) return 'Buenos días';
    if (hour >= 12 && hour < 19) return 'Buenas tardes';
    return 'Buenas noches';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final personalizedAsync = ref.watch(personalizedSectionsProvider);
    final topChartsAsync = ref.watch(topChartsProvider);
    final playlistsAsync = ref.watch(editorialPlaylistsProvider);
    final newReleasesAsync = ref.watch(newReleasesProvider);

    return SafeArea(
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // Header Top Bar
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
                        Builder(
                          builder: (ctx) {
                            final profileAsync = ref.watch(profileProvider);
                            final user = ref.watch(currentUserProvider);
                            final isLocalMode = ref.watch(localModeProvider);
                            // 7.I.4: seed local en vez de `profiles.avatar_seed`
                            // (que no existe sin cuenta) cuando aplica.
                            final localSeedAsync = isLocalMode ? ref.watch(localAvatarSeedProvider) : null;
                            final seed = isLocalMode
                                ? (localSeedAsync?.value ?? 'default')
                                : (profileAsync.value?['avatar_seed'] as String? ?? user?.id ?? 'default');
                            final avatarUrl = 'https://api.dicebear.com/9.x/adventurer-neutral/svg?seed=$seed';

                            return GestureDetector(
                              onTap: () => context.push('/settings'),
                              child: ClipRRect(
                                borderRadius: const BorderRadius.all(Radius.circular(999)),
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  color: AppTheme.surfaceActive,
                                  child: SvgPicture.network(
                                    avatarUrl,
                                    width: 32,
                                    height: 32,
                                    fit: BoxFit.cover,
                                    placeholderBuilder: (_) => const Icon(
                                      Icons.person,
                                      size: 20,
                                      color: AppTheme.secondary,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 10),
                      ],
                      Text(
                        _getGreeting(),
                        style: (isDesktop
                                ? Theme.of(context).textTheme.headlineMedium
                                : Theme.of(context).textTheme.titleLarge)
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: AppTheme.primary,
                              fontSize: isDesktop ? 26 : 20,
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
                          icon: Icon(AppIcons.broken(SolarIcons.Bell), color: AppTheme.primary, size: 22),
                          onPressed: () => AppToast.show(context, message: 'Notificaciones próximamente'),
                        ),
                      ),
                      Tooltip(
                        message: 'Configuración',
                        child: IconButton(
                          icon: Icon(AppIcons.broken(SolarIcons.Settings), color: AppTheme.primary, size: 22),
                          onPressed: () => context.push('/settings'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Fase 7.G.6: tarjeta compacta de estadísticas semanales (Documento
          // Maestro §2.1.1). Sin tarjeta si no hay datos (usuario nuevo), en
          // vez de mostrarla en 0 -- evita ruido visual en el primer uso.
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverToBoxAdapter(
              child: Consumer(
                builder: (context, ref, _) {
                  final weeklyAsync = ref.watch(weeklyStatsProvider);
                  final snapshot = weeklyAsync.value;
                  if (snapshot == null || snapshot.isEmpty) return const SizedBox.shrink();

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Material(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => context.push('/stats'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          child: Row(
                            children: [
                              Icon(AppIcons.broken(SolarIcons.Chart), color: AppTheme.accent, size: 22),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Tus minutos esta semana: ${snapshot.totalMinutes > 0 ? "${snapshot.totalMinutes} min" : "< 1 min"}',
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ),
                              Text('Ver más', style: Theme.of(context).textTheme.labelMedium),
                              const SizedBox(width: 4),
                              Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary, size: 16),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Acceso rápido: Tus me gusta y accesos directos
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverToBoxAdapter(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final crossCount = constraints.maxWidth > 700 ? 4 : 2;
                  final quickItems = [
                    {
                      'title': 'Tus me gusta',
                      'cover': '',
                      'isLiked': true,
                      'route': '/playlist/liked',
                    },
                    {
                      'title': 'Top Global 50',
                      'cover': 'https://e-cdns-images.dzcdn.net/images/cover/d41d8cd98f00b204e9800998ecf8427e/250x250-000000-80-0-0.jpg',
                      'route': '/search',
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
                    itemCount: quickItems.length,
                    itemBuilder: (ctx, i) {
                      final item = quickItems[i];
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
                                          child: Icon(AppIcons.bold(SolarIcons.Heart), color: Colors.white, size: 24),
                                        )
                                      : CachedNetworkImage(
                                          imageUrl: item['cover'] as String,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, _, _) => Container(color: AppTheme.surfaceHover),
                                        ),
                                ),
                              ),
                              const SizedBox(width: 10),
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
                              const SizedBox(width: 14),
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

          // Sección: Hecho para ti (Personalizada según el historial de escucha)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverToBoxAdapter(
              child: personalizedAsync.when(
                data: (sections) {
                  if (sections.isEmpty) return const SizedBox.shrink();
                  return Column(
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
                      ...sections.map((sec) => _buildArtistSection(context, ref, sec, isDesktop)),
                    ],
                  );
                },
                loading: () => _buildHorizontalSkeleton(isDesktop),
                error: (e, s) => const SizedBox.shrink(),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Sección: Éxitos Globales (Top Charts)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverToBoxAdapter(
              child: topChartsAsync.when(
                data: (tracks) {
                  if (tracks.isEmpty) return const SizedBox.shrink();
                  final syncoraTracks = tracks.map((t) => t.toSyncoraTrack()).toList();
                  final displayTracks = syncoraTracks.take(5).toList();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Éxitos Globales',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: AppTheme.primary,
                            ),
                      ),
                      const SizedBox(height: 12),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: displayTracks.length,
                        itemBuilder: (ctx, i) {
                          final track = displayTracks[i];
                          final currentTrack = ref.watch(currentTrackProvider);
                          final isPlaying = currentTrack?.id == track.id;

                          return TrackTile(
                            track: track,
                            isPlaying: isPlaying,
                            onTap: () {
                              final controller = ref.read(syncoraPlayerControllerProvider.notifier);
                              controller.setQueue(syncoraTracks, startIndex: i);
                            },
                            onAddToQueue: () {
                              ref.read(syncoraPlayerControllerProvider.notifier).addToQueue(track);
                            },
                          );
                        },
                      ),
                    ],
                  );
                },
                loading: () => const SkeletonBox(height: 180, borderRadius: 16),
                error: (e, s) => const SizedBox.shrink(),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),

          // Sección: Playlists Editoriales
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverToBoxAdapter(
              child: playlistsAsync.when(
                data: (playlists) {
                  if (playlists.isEmpty) return const SizedBox.shrink();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Playlists Editoriales',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: AppTheme.primary,
                            ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: isDesktop ? 240 : 200,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: playlists.length,
                          separatorBuilder: (ctx, index) => const SizedBox(width: 16),
                          itemBuilder: (ctx, i) {
                            final pl = playlists[i];
                            return SizedBox(
                              width: isDesktop ? 180 : 140,
                              child: PlaylistCard(
                                title: pl.title,
                                subtitle: '${pl.nbTracks} canciones • ${pl.userName}',
                                coverUrl: pl.pictureUrl,
                                onTap: () => AppToast.show(context, message: 'Playlist: ${pl.title}'),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
                loading: () => _buildHorizontalSkeleton(isDesktop),
                error: (e, s) => const SizedBox.shrink(),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),

          // Sección: Nuevos Lanzamientos
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverToBoxAdapter(
              child: newReleasesAsync.when(
                data: (albums) {
                  if (albums.isEmpty) return const SizedBox.shrink();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Nuevos Lanzamientos',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: AppTheme.primary,
                            ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: isDesktop ? 240 : 200,
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
                                subtitle: 'Álbum • ${album.artistName}',
                                coverUrl: album.coverUrl,
                                onTap: () => context.push('/album/${album.id}'),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
                loading: () => _buildHorizontalSkeleton(isDesktop),
                error: (e, s) => const SizedBox.shrink(),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }

  Widget _buildArtistSection(
    BuildContext context,
    WidgetRef ref,
    PersonalizedArtistSection sec,
    bool isDesktop,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'Basado en tu gusto: ${sec.artist.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => context.push('/artist/${sec.artist.id}'),
              child: const Text('Ver artista', style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: isDesktop ? 240 : 200,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: sec.tracks.length,
            separatorBuilder: (ctx, index) => const SizedBox(width: 16),
            itemBuilder: (ctx, i) {
              final track = sec.tracks[i];
              return SizedBox(
                width: isDesktop ? 180 : 140,
                child: PlaylistCard(
                  title: track.title,
                  subtitle: track.artistName,
                  coverUrl: track.coverUrl,
                  onTap: () {
                    final syncoraTracks = sec.tracks.map((t) => t.toSyncoraTrack()).toList();
                    ref.read(syncoraPlayerControllerProvider.notifier).setQueue(syncoraTracks, startIndex: i);
                  },
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildHorizontalSkeleton(bool isDesktop) {
    return SizedBox(
      height: isDesktop ? 240 : 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: 4,
        separatorBuilder: (ctx, index) => const SizedBox(width: 16),
        itemBuilder: (ctx, index) => SkeletonBox(
          width: isDesktop ? 180 : 140,
          height: 200,
          borderRadius: 16,
        ),
      ),
    );
  }
}
