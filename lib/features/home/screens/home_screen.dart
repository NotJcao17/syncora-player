import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../core/cache/api_cache.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/horizontal_scroller.dart';
import '../../../core/widgets/playlist_card.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../../data/apis/deezer_catalog_providers.dart';
import '../../../data/models/deezer/deezer_playlist.dart';
import '../../../data/sync/sync_cache_manager.dart';
import '../../../data/sync/sync_service.dart';
import '../../auth/auth_provider.dart';
import '../../auth/local_mode_provider.dart';
import '../../stats/stats_providers.dart';
import '../home_providers.dart';
import '../mixes/mix_models.dart';
import '../mixes/mix_providers.dart';
import '../widgets/home_sections.dart';
import '../widgets/mix_cover.dart';
import '../widgets/weekly_highlights_panel.dart';

/// Pantalla de Inicio.
///
/// Orden pensado para que **lo instantáneo y lo que funciona sin conexión se
/// pinte primero**: resumen de la semana, escuchado recientemente y accesos
/// rápidos salen enteros de Drift, así que aparecen en el primer frame incluso
/// en un arranque en frío o sin red. Todo lo que depende de Deezer viene
/// después y está cacheado en disco con TTL (ver `api_cache.dart`), así que a
/// partir del segundo arranque también se pinta al instante.
///
/// Regla de diseño de esta pantalla: **ninguna canción individual se presenta
/// como si fuera una colección**. Las tarjetas son siempre playlists, álbumes,
/// mixes, artistas o géneros. Las únicas canciones sueltas que aparecen son
/// las tres filas del resumen semanal, que son un dato estadístico y se ven
/// como tal.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  String _getGreeting() {
    final mexicoNow = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    final hour = mexicoNow.hour;
    if (hour >= 5 && hour < 12) return 'Buenos días';
    if (hour >= 12 && hour < 19) return 'Buenas tardes';
    return 'Buenas noches';
  }

  /// Mismo refresco por TTL que hace la pantalla de Estadísticas, compartiendo
  /// su clave de caché: Inicio muestra el resumen semanal, así que entrar acá
  /// tras un rato también debe traer lo que se escuchó en otro dispositivo.
  /// `isExpired`/`markSynced` lo vuelven idempotente, por eso puede dispararse
  /// desde `build` sin entrar en bucle.
  void _maybeRefreshStats(WidgetRef ref) {
    final cacheManager = ref.read(syncCacheManagerProvider);
    if (!cacheManager.isExpired('stats')) return;
    cacheManager.markSynced('stats');
    Future.microtask(() async {
      if (!ref.read(localModeProvider)) {
        await ref.read(syncServiceProvider).syncListeningHistory();
      }
      ref.invalidate(weeklyStatsProvider);
      ref.invalidate(monthlyStatsProvider);
      ref.invalidate(yearlyStatsProvider);
      ref.invalidate(allTimeStatsProvider);
      ref.invalidate(weeklyHighlightsProvider);
    });
  }

  /// Recarga las secciones locales y las de catálogo.
  ///
  /// Para las de catálogo no basta con invalidar el provider: volvería a leer
  /// el mismo archivo de caché todavía fresco y el gesto no haría nada
  /// visible. Por eso se borran antes sus claves — solo las de las secciones
  /// que este gesto refresca, no el caché entero.
  Future<void> _refreshAll(WidgetRef ref) async {
    final cache = ref.read(apiCacheProvider);
    await Future.wait([
      cache.removeWithPrefix('editorial_playlists'),
      cache.removeWithPrefix('chart_albums'),
      cache.removeWithPrefix('country_tops'),
      cache.removeWithPrefix('artist_albums_'),
    ]);

    ref.invalidate(recentlyPlayedProvider);
    ref.invalidate(weeklyHighlightsProvider);
    ref.invalidate(mixesProvider);
    ref.invalidate(editorialPlaylistsProvider);
    ref.invalidate(newReleasesProvider);
    ref.invalidate(newReleasesFromArtistsProvider);
    ref.invalidate(deezerCountryTopsProvider);
    ref.invalidate(homeCountryTopsProvider);
    ref.invalidate(relatedArtistsProvider);
    ref.invalidate(deezerGenresProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _maybeRefreshStats(ref);

    // Cuando vuelve la conexión, Inicio se recarga solo en vez de quedarse en
    // "No pudimos cargar el contenido" esperando a que el usuario pulse
    // Reintentar. Solo en la transición offline -> online: `ref.listen` no se
    // dispara en los rebuilds normales.
    ref.listen<AsyncValue<bool>>(isConnectedProvider, (previous, next) {
      final wasConnected = previous?.value ?? true;
      final isConnected = next.value ?? true;
      if (wasConnected || !isConnected) return;
      ref.invalidate(editorialPlaylistsProvider);
      ref.invalidate(newReleasesProvider);
      ref.invalidate(newReleasesFromArtistsProvider);
      ref.invalidate(homeCountryTopsProvider);
      ref.invalidate(relatedArtistsProvider);
      ref.invalidate(deezerGenresProvider);
      ref.invalidate(mixesProvider);
    });

    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final horizontalPadding = isDesktop ? 32.0 : 20.0;

    final editorialAsync = ref.watch(editorialPlaylistsProvider);
    final countryTopsAsync = ref.watch(homeCountryTopsProvider);
    final genresAsync = ref.watch(deezerGenresProvider);

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () => _refreshAll(ref),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _buildHeader(context, ref, isDesktop, horizontalPadding),

            // --- Todo lo de abajo es local: se pinta sin red y sin esperas ---
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: const SliverToBoxAdapter(child: WeeklyHighlightsPanel()),
            ),
            _buildQuickAccess(context, horizontalPadding),
            _buildRecentlyPlayed(context, ref, isDesktop, horizontalPadding),
            _buildMixes(context, ref, isDesktop, horizontalPadding),

            // --- De acá para abajo, catálogo de Deezer (cacheado) ---
            _buildNewReleases(context, ref, isDesktop, horizontalPadding),
            _buildCountryTops(context, ref, isDesktop, horizontalPadding, countryTopsAsync),
            _buildEditorial(context, ref, isDesktop, horizontalPadding, editorialAsync),
            _buildRelatedArtists(context, ref, isDesktop, horizontalPadding),
            _buildGenres(context, ref, isDesktop, horizontalPadding),

            // El aviso de "sin contenido" va al final: si las secciones
            // locales sí tienen datos, no tiene sentido gritar un error
            // arriba de todo solo porque Deezer no contesta.
            if (_catalogIsEmpty(editorialAsync, countryTopsAsync, genresAsync))
              _buildEmptyCatalogNotice(context, ref, horizontalPadding),

            const SliverToBoxAdapter(child: SizedBox(height: 48)),
          ],
        ),
      ),
    );
  }

  bool _catalogIsEmpty(AsyncValue<List> a, AsyncValue<List> b, AsyncValue<List> c) {
    if (a.isLoading || b.isLoading || c.isLoading) return false;
    return (a.value?.isEmpty ?? true) && (b.value?.isEmpty ?? true) && (c.value?.isEmpty ?? true);
  }

  // -------------------------------------------------------------------------
  // Cabecera
  // -------------------------------------------------------------------------

  Widget _buildHeader(BuildContext context, WidgetRef ref, bool isDesktop, double padding) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: padding, vertical: isDesktop ? 24 : 16),
      sliver: SliverToBoxAdapter(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  if (!isDesktop) ...[
                    const _ProfileAvatar(),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text(
                      _getGreeting(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                  ),
                ],
              ),
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
    );
  }

  // -------------------------------------------------------------------------
  // Accesos rápidos
  // -------------------------------------------------------------------------

  Widget _buildQuickAccess(BuildContext context, double padding) {
    // Antes había acá un "Top Global 50" que llevaba a `/search` y cuya portada
    // era una URL con el hash MD5 de la cadena vacía — o sea, una imagen rota
    // permanente. Los tops de verdad ahora tienen su propia sección.
    final items = [
      (
        title: 'Tus me gusta',
        icon: AppIcons.bold(SolarIcons.Heart),
        gradient: AppTheme.gradientLiked,
        route: '/playlist/liked',
      ),
      (
        title: 'Descargas',
        icon: AppIcons.broken(SolarIcons.DownloadMinimalistic),
        gradient: null,
        route: '/downloads',
      ),
      (
        title: 'Estadísticas',
        icon: AppIcons.broken(SolarIcons.Chart),
        gradient: null,
        route: '/stats',
      ),
    ];

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(padding, 4, padding, 0),
      sliver: SliverToBoxAdapter(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final crossCount = constraints.maxWidth > 700 ? 3 : 1;
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
                return InkWell(
                  onTap: () => context.push(item.route),
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
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              gradient: item.gradient,
                              color: item.gradient == null ? AppTheme.surfaceHover : null,
                            ),
                            child: Icon(item.icon, color: Colors.white, size: 22),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            item.title,
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
    );
  }

  // -------------------------------------------------------------------------
  // Secciones
  // -------------------------------------------------------------------------

  Widget _buildRecentlyPlayed(BuildContext context, WidgetRef ref, bool isDesktop, double padding) {
    final async = ref.watch(recentlyPlayedProvider);
    final items = async.value ?? const [];
    if (items.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return HomeSection(
      title: 'Escuchado recientemente',
      isDesktop: isDesktop,
      padding: padding,
      child: HomeCardRow(
        isDesktop: isDesktop,
        padding: padding,
        itemCount: items.length,
        itemBuilder: (i) {
          final item = items[i];
          return PlaylistCard(
            title: item.title,
            subtitle: item.subtitle,
            coverUrl: item.coverUrl,
            playlistId: item.localPlaylistId,
            onTap: () => context.push(item.route),
          );
        },
      ),
    );
  }

  Widget _buildMixes(BuildContext context, WidgetRef ref, bool isDesktop, double padding) {
    final async = ref.watch(mixesProvider);

    if (async.isLoading) {
      return HomeSection(
        title: 'Tus mixes',
        isDesktop: isDesktop,
        padding: padding,
        child: HomeCardRowSkeleton(isDesktop: isDesktop, padding: padding),
      );
    }

    final mixes = async.value ?? const <SyncoraMix>[];
    if (mixes.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return HomeSection(
      title: 'Tus mixes',
      subtitle: 'Se renuevan solos. Guarda uno si quieres conservarlo tal cual.',
      isDesktop: isDesktop,
      padding: padding,
      child: HomeCardRow(
        isDesktop: isDesktop,
        padding: padding,
        itemCount: mixes.length,
        itemBuilder: (i) {
          final mix = mixes[i];
          return PlaylistCard(
            title: mix.title,
            subtitle: '${mix.tracks.length} canciones',
            coverUrl: mix.coverUrl,
            coverOverride: mix.usesGeneratedCover ? MixCover(kind: mix.kind) : null,
            onTap: () => context.push('/mix/${Uri.encodeComponent(mix.key)}'),
          );
        },
      ),
    );
  }

  Widget _buildNewReleases(BuildContext context, WidgetRef ref, bool isDesktop, double padding) {
    final fromArtists = ref.watch(newReleasesFromArtistsProvider);
    final fallback = ref.watch(newReleasesProvider);

    // Si el usuario tiene historial, se prefieren las novedades de SUS
    // artistas; si no (instalación nueva), el chart de álbumes hace de
    // respaldo en vez de dejar un hueco.
    final personal = fromArtists.value ?? const [];
    final usePersonal = personal.isNotEmpty;
    final albums = usePersonal ? personal : (fallback.value ?? const []);

    if (albums.isEmpty) {
      if (fromArtists.isLoading || fallback.isLoading) {
        return HomeSection(
          title: 'Novedades',
          isDesktop: isDesktop,
          padding: padding,
          child: HomeCardRowSkeleton(isDesktop: isDesktop, padding: padding),
        );
      }
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return HomeSection(
      title: usePersonal ? 'Novedades de tus artistas' : 'Álbumes destacados',
      isDesktop: isDesktop,
      padding: padding,
      child: HomeCardRow(
        isDesktop: isDesktop,
        padding: padding,
        itemCount: albums.length,
        itemBuilder: (i) {
          final album = albums[i];
          return PlaylistCard(
            title: album.title,
            subtitle: usePersonal && album.releaseDate.isNotEmpty
                ? '${album.artistName} • ${album.releaseDate}'
                : 'Álbum • ${album.artistName}',
            coverUrl: album.coverUrl,
            onTap: () => context.push('/album/${album.id}'),
          );
        },
      ),
    );
  }

  Widget _buildCountryTops(
    BuildContext context,
    WidgetRef ref,
    bool isDesktop,
    double padding,
    AsyncValue<List<DeezerPlaylist>> async,
  ) {
    if (async.isLoading) {
      return HomeSection(
        title: 'Tops del mundo',
        isDesktop: isDesktop,
        padding: padding,
        child: HomeCardRowSkeleton(isDesktop: isDesktop, padding: padding),
      );
    }

    final all = async.value ?? const <DeezerPlaylist>[];
    if (all.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    // Solo los destacados en Inicio; el resto (son más de 100 países) vive
    // detrás de "Ver todos", que abre un selector buscable — así la sección no
    // se vuelve invasiva.
    final featured = all.take(homeFeaturedCountryTops.length).toList();

    return HomeSection(
      title: 'Tops del mundo',
      isDesktop: isDesktop,
      padding: padding,
      action: all.length > featured.length
          ? HomeSectionAction(
              label: 'Ver todos',
              onPressed: () => showCountryTopsPicker(context, all),
            )
          : null,
      child: HomeCardRow(
        isDesktop: isDesktop,
        padding: padding,
        itemCount: featured.length,
        itemBuilder: (i) {
          final playlist = featured[i];
          return PlaylistCard(
            title: playlist.title,
            subtitle: '${playlist.nbTracks} canciones',
            coverUrl: playlist.pictureUrl,
            onTap: () => context.push('/deezer-playlist/${playlist.id}'),
          );
        },
      ),
    );
  }

  Widget _buildEditorial(
    BuildContext context,
    WidgetRef ref,
    bool isDesktop,
    double padding,
    AsyncValue<List<DeezerPlaylist>> async,
  ) {
    if (async.isLoading) {
      return HomeSection(
        title: 'Playlists editoriales',
        isDesktop: isDesktop,
        padding: padding,
        child: HomeCardRowSkeleton(isDesktop: isDesktop, padding: padding),
      );
    }

    final playlists = async.value ?? const <DeezerPlaylist>[];
    if (playlists.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return HomeSection(
      title: 'Playlists editoriales',
      isDesktop: isDesktop,
      padding: padding,
      child: HomeCardRow(
        isDesktop: isDesktop,
        padding: padding,
        itemCount: playlists.length,
        itemBuilder: (i) {
          final playlist = playlists[i];
          return PlaylistCard(
            title: playlist.title,
            subtitle: '${playlist.nbTracks} canciones • ${playlist.userName}',
            coverUrl: playlist.pictureUrl,
            // Antes esto solo mostraba un toast con el nombre: no había
            // ninguna forma de abrir una playlist editorial.
            onTap: () => context.push('/deezer-playlist/${playlist.id}'),
          );
        },
      ),
    );
  }

  Widget _buildRelatedArtists(BuildContext context, WidgetRef ref, bool isDesktop, double padding) {
    final suggestion = ref.watch(relatedArtistsProvider).value;
    if (suggestion == null || suggestion.artists.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return HomeSection(
      title: 'Porque escuchaste a ${suggestion.seedArtistName}',
      isDesktop: isDesktop,
      padding: padding,
      child: HorizontalScroller(
        height: isDesktop ? 190 : 160,
        padding: EdgeInsets.symmetric(horizontal: padding),
        itemCount: suggestion.artists.length,
        itemBuilder: (ctx, i) {
          final artist = suggestion.artists[i];
          return HomeArtistCircle(
            name: artist.name,
            pictureUrl: artist.pictureUrl,
            size: isDesktop ? 130 : 110,
            onTap: () => context.push('/artist/${artist.id}'),
          );
        },
      ),
    );
  }

  Widget _buildGenres(BuildContext context, WidgetRef ref, bool isDesktop, double padding) {
    final genres = ref.watch(deezerGenresProvider).value ?? const [];
    if (genres.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return HomeSection(
      title: 'Explorar por género',
      isDesktop: isDesktop,
      padding: padding,
      child: HorizontalScroller(
        height: 96,
        padding: EdgeInsets.symmetric(horizontal: padding),
        separatorWidth: 12,
        itemCount: genres.length,
        itemBuilder: (ctx, i) {
          final genre = genres[i];
          return SizedBox(
            width: 160,
            child: HomeGenreTile(
              name: genre.name,
              imageUrl: genre.pictureUrl,
              onTap: () => context.push(
                '/genre/${genre.id}?name=${Uri.encodeComponent(genre.name)}',
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyCatalogNotice(BuildContext context, WidgetRef ref, double padding) {
    final isConnected = ref.watch(isConnectedProvider).value ?? true;

    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: padding, vertical: 32),
      sliver: SliverToBoxAdapter(
        child: Column(
          children: [
            Icon(
              AppIcons.broken(isConnected ? SolarIcons.Refresh : SolarIcons.WiFiRouter),
              color: AppTheme.muted,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              isConnected ? 'No pudimos cargar el contenido' : 'Sin conexión',
              style: const TextStyle(color: AppTheme.primary, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              isConnected
                  ? 'Revisa tu conexión e inténtalo de nuevo.'
                  : 'Tu biblioteca y tus descargas siguen disponibles.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _refreshAll(ref),
              icon: Icon(AppIcons.broken(SolarIcons.Refresh), size: 16),
              label: const Text('Reintentar'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                side: const BorderSide(color: AppTheme.surfaceHover),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileAvatar extends ConsumerWidget {
  const _ProfileAvatar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(profileProvider);
    final user = ref.watch(currentUserProvider);
    final isLocalMode = ref.watch(localModeProvider);
    // 7.I.4: seed local en vez de `profiles.avatar_seed` (que no existe sin
    // cuenta) cuando aplica.
    final localSeedAsync = isLocalMode ? ref.watch(localAvatarSeedProvider) : null;
    final seed = isLocalMode
        ? (localSeedAsync?.value ?? 'default')
        : (profileAsync.value?['avatar_seed'] as String? ?? user?.id ?? 'default');

    return GestureDetector(
      onTap: () => context.push('/settings'),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        child: Container(
          width: 32,
          height: 32,
          color: AppTheme.surfaceActive,
          child: SvgPicture.network(
            'https://api.dicebear.com/9.x/adventurer-neutral/svg?seed=$seed',
            width: 32,
            height: 32,
            fit: BoxFit.cover,
            placeholderBuilder: (_) => const Icon(Icons.person, size: 20, color: AppTheme.secondary),
          ),
        ),
      ),
    );
  }
}

/// Selector de tops por país.
///
/// Ventana centrada en escritorio y hoja en móvil, como manda la guía de UI
/// del proyecto. Con más de 100 países, lleva buscador: recorrer la lista a
/// mano sería peor que no tener la función.
Future<void> showCountryTopsPicker(BuildContext context, List<DeezerPlaylist> playlists) {
  final isDesktop = MediaQuery.of(context).size.width >= 768;

  if (isDesktop) {
    return showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.background,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
        child: SizedBox(
          width: 520,
          height: 600,
          child: _CountryTopsList(playlists: playlists),
        ),
      ),
    );
  }

  return showModalBottomSheet(
    context: context,
    backgroundColor: AppTheme.background,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.75,
      child: _CountryTopsList(playlists: playlists),
    ),
  );
}

class _CountryTopsList extends StatefulWidget {
  final List<DeezerPlaylist> playlists;

  const _CountryTopsList({required this.playlists});

  @override
  State<_CountryTopsList> createState() => _CountryTopsListState();
}

class _CountryTopsListState extends State<_CountryTopsList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.playlists
        : widget.playlists.where((p) => p.title.toLowerCase().contains(query)).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Tops por país',
            style: TextStyle(color: AppTheme.primary, fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          TextField(
            autofocus: false,
            style: const TextStyle(color: AppTheme.primary),
            decoration: InputDecoration(
              hintText: 'Buscar país…',
              hintStyle: const TextStyle(color: AppTheme.secondary),
              prefixIcon: Icon(AppIcons.broken(SolarIcons.Magnifer), color: AppTheme.secondary, size: 18),
              filled: true,
              fillColor: AppTheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text(
                      'Ningún país coincide',
                      style: TextStyle(color: AppTheme.secondary),
                    ),
                  )
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) {
                      final playlist = filtered[i];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: playlist.pictureUrl.isEmpty
                                ? Container(color: AppTheme.surfaceHover)
                                : CachedNetworkImage(imageUrl: playlist.pictureUrl, fit: BoxFit.cover),
                          ),
                        ),
                        title: Text(
                          playlist.title,
                          style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${playlist.nbTracks} canciones',
                          style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          context.push('/deezer-playlist/${playlist.id}');
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Esqueleto reutilizado mientras cargan las filas de tarjetas.
class HomeCardRowSkeleton extends StatelessWidget {
  final bool isDesktop;
  final double padding;

  const HomeCardRowSkeleton({super.key, required this.isDesktop, required this.padding});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: isDesktop ? 240 : 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: padding),
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (ctx, i) => SizedBox(
          width: isDesktop ? 180 : 140,
          child: const SkeletonBox(height: 180, borderRadius: 16),
        ),
      ),
    );
  }
}
