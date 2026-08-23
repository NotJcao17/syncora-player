import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../auth/local_mode_provider.dart';
import '../stats_calculator.dart';
import '../stats_providers.dart';

/// Fase 7.G.5 -- pantalla de Estadísticas (`/stats`): 3 pestañas (Semanal /
/// Mensual / Anual) + acción "Desde el inicio". En modo local (7.I.6), solo
/// Semanal y Mensual están disponibles -- Anual y Desde el inicio dependen
/// de `user_stats_monthly`, que solo se llena en la nube vía cron.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLocalMode = ref.watch(localModeProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => context.pop(),
                    icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: AppTheme.primary, size: 22),
                  ),
                  const SizedBox(width: 4),
                  Text('Estadísticas', style: Theme.of(context).textTheme.headlineSmall),
                ],
              ),
            ),
            TabBar(
              controller: _tabController,
              labelColor: AppTheme.primary,
              unselectedLabelColor: AppTheme.muted,
              indicatorColor: AppTheme.accent,
              tabs: const [
                Tab(text: 'Semanal'),
                Tab(text: 'Mensual'),
                Tab(text: 'Anual'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _RawStatsTab(asyncSnapshot: ref.watch(weeklyStatsProvider), showGenres: false),
                  _RawStatsTab(asyncSnapshot: ref.watch(monthlyStatsProvider), showGenres: true),
                  isLocalMode ? const _LocalOnlyNotice() : const _YearlyTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalOnlyNotice extends StatelessWidget {
  const _LocalOnlyNotice();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.broken(SolarIcons.Crown), color: AppTheme.muted, size: 40),
            const SizedBox(height: 16),
            Text(
              'Disponible solo con cuenta',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Crea una cuenta para ver tus estadísticas anuales y de todo el tiempo.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// `StatelessWidget` (no `ConsumerWidget`) porque Semanal/Mensual pasaron a
// `StreamProvider` (bug real: no se actualizaban solos al escuchar
// canciones nuevas) -- el `AsyncValue` ya viene resuelto por el `ref.watch`
// del `build()` de `_StatsScreenState`, así que esta vista no necesita `ref`
// propio.
class _RawStatsTab extends StatelessWidget {
  final AsyncValue<StatsSnapshot> asyncSnapshot;
  final bool showGenres;

  const _RawStatsTab({required this.asyncSnapshot, required this.showGenres});

  @override
  Widget build(BuildContext context) {
    return asyncSnapshot.when(
      loading: () => const _StatsLoadingSkeleton(),
      error: (_, _) => const _StatsEmptyState(),
      data: (snapshot) {
        if (snapshot.isEmpty) return const _StatsEmptyState();
        return _StatsContent(snapshot: snapshot, showGenres: showGenres, showMostActiveMonth: false);
      },
    );
  }
}

class _YearlyTab extends ConsumerWidget {
  const _YearlyTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSnapshot = ref.watch(yearlyStatsProvider);

    return asyncSnapshot.when(
      loading: () => const _StatsLoadingSkeleton(),
      error: (_, _) => const _StatsEmptyState(),
      data: (snapshot) {
        if (snapshot.isEmpty) return const _StatsEmptyState();
        // Padding horizontal ya lo pone `_StatsContent` (bug real de
        // pruebas manuales: texto pegado al borde derecho) -- solo
        // vertical acá para no duplicarlo.
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            _StatsContent(snapshot: snapshot, showGenres: true, showMostActiveMonth: true),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const _WrappedStoriesScreen()),
                    ),
                    icon: Icon(AppIcons.broken(SolarIcons.Chart), size: 18),
                    label: const Text('Ver Wrapped'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const _AllTimeScreen()),
                    ),
                    icon: Icon(AppIcons.broken(SolarIcons.Calendar), size: 18),
                    label: const Text('Ver desde el inicio'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AllTimeScreen extends ConsumerWidget {
  const _AllTimeScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSnapshot = ref.watch(allTimeStatsProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: const Text('Desde el inicio'),
      ),
      body: asyncSnapshot.when(
        loading: () => const _StatsLoadingSkeleton(),
        error: (_, _) => const _StatsEmptyState(),
        data: (snapshot) {
          if (snapshot.isEmpty) return const _StatsEmptyState();
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              _StatsContent(snapshot: snapshot, showGenres: true, showMostActiveMonth: false),
            ],
          );
        },
      ),
    );
  }
}

class _StatsLoadingSkeleton extends StatelessWidget {
  const _StatsLoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        const SkeletonBox(width: 160, height: 28),
        const SizedBox(height: 24),
        const SkeletonBox(width: double.infinity, height: 18, margin: EdgeInsets.only(bottom: 12)),
        for (var i = 0; i < 5; i++)
          const SkeletonBox(width: double.infinity, height: 56, margin: EdgeInsets.only(bottom: 8)),
      ],
    );
  }
}

class _StatsEmptyState extends StatelessWidget {
  const _StatsEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.broken(SolarIcons.Graph), color: AppTheme.muted, size: 40),
            const SizedBox(height: 16),
            Text(
              'Todavía no hay suficiente historial',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Sigue escuchando música y tus estadísticas aparecerán acá.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsContent extends ConsumerWidget {
  final StatsSnapshot snapshot;
  final bool showGenres;
  final bool showMostActiveMonth;

  const _StatsContent({
    required this.snapshot,
    required this.showGenres,
    required this.showMostActiveMonth,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistsAsync = ref.watch(enrichedArtistsProvider(snapshot.topArtists));
    final tracksAsync = ref.watch(enrichedTracksProvider(snapshot.topTracks));

    // Bug real (pruebas manuales): sin padding horizontal acá Y con
    // `ListTile(contentPadding: EdgeInsets.zero)` en cada fila de abajo, el
    // texto de la derecha (minutos, reproducciones) quedaba pegado literal
    // al borde de la pantalla -- las otras vistas (Anual/Desde el inicio)
    // no lo sufrían porque las envuelve un `ListView` con 20px de padding
    // propio; Semanal/Mensual pasan por `_RawStatsTab`, que no envuelve
    // nada.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${snapshot.totalMinutes} min escuchados',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          if (showMostActiveMonth && snapshot.mostActiveMonth != null) ...[
            const SizedBox(height: 4),
            Text(
              'Mes más activo: ${_monthLabel(snapshot.mostActiveMonth!)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 20),
          Text('Top artistas', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          artistsAsync.when(
            loading: () => const SkeletonBox(width: double.infinity, height: 56),
            error: (_, _) => const SizedBox.shrink(),
            data: (artists) => Column(
              children: [
                for (final e in artists)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(backgroundImage: NetworkImage(e.artist.pictureUrl)),
                    title: Text(e.artist.name),
                    trailing: Text('${e.entry.minutes} min', style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('Top canciones', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          tracksAsync.when(
            loading: () => const SkeletonBox(width: double.infinity, height: 56),
            error: (_, _) => const SizedBox.shrink(),
            data: (tracks) => Column(
              children: [
                for (final e in tracks)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(e.track.coverUrl, width: 44, height: 44, fit: BoxFit.cover),
                    ),
                    title: Text(e.track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(e.track.artistName, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(
                      '${e.entry.playCount} reproducciones',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          if (showGenres && snapshot.topGenres.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Top géneros', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final g in snapshot.topGenres.take(10))
                  Chip(
                    backgroundColor: AppTheme.surfaceHover,
                    label: Text('${g.genre} · ${g.minutes} min'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _monthLabel(DateTime month) {
    const names = [
      'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
    ];
    return '${names[month.month - 1]} ${month.year}';
  }
}

/// Fase 7.G.7 -- tarjetas tipo stories compartibles como imagen (D-20: solo
/// imagen, sin URL pública).
class _WrappedStoriesScreen extends ConsumerStatefulWidget {
  const _WrappedStoriesScreen();

  @override
  ConsumerState<_WrappedStoriesScreen> createState() => _WrappedStoriesScreenState();
}

class _WrappedStoriesScreenState extends ConsumerState<_WrappedStoriesScreen> {
  final PageController _pageController = PageController();
  final List<GlobalKey> _cardKeys = List.generate(5, (_) => GlobalKey());
  bool _isSharing = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _share(int index) async {
    if (_isSharing) return;
    setState(() => _isSharing = true);
    try {
      final boundary =
          _cardKeys[index].currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final bytes = byteData.buffer.asUint8List();

      final dir = await getTemporaryDirectory();
      final file = await _writeTempPng(dir.path, bytes);
      await Share.shareXFiles([XFile(file.path)], text: 'Mi Wrapped de Syncora Player');
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  Future<File> _writeTempPng(String dirPath, Uint8List bytes) async {
    final file = File('$dirPath/syncora_wrapped_${DateTime.now().millisecondsSinceEpoch}.png');
    return file.writeAsBytes(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final asyncSnapshot = ref.watch(yearlyStatsProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: asyncSnapshot.when(
        loading: () => const Center(child: SkeletonBox(width: 240, height: 400)),
        error: (_, _) => const _StatsEmptyState(),
        data: (snapshot) {
          final artistsAsync = ref.watch(enrichedArtistsProvider(snapshot.topArtists));
          final tracksAsync = ref.watch(enrichedTracksProvider(snapshot.topTracks));

          final cards = [
            _wrappedCard(0, 'Este año escuchaste', '${snapshot.totalMinutes} minutos'),
            _wrappedCard(
              1,
              'Tus artistas top',
              artistsAsync.value?.take(5).map((e) => e.artist.name).join('\n') ?? '',
            ),
            _wrappedCard(
              2,
              'Tus canciones top',
              tracksAsync.value?.take(5).map((e) => e.track.title).join('\n') ?? '',
            ),
            _wrappedCard(
              3,
              'Tus géneros top',
              snapshot.topGenres.take(5).map((g) => g.genre).join('\n'),
            ),
            _wrappedCard(
              4,
              'Tu mes más activo',
              snapshot.mostActiveMonth != null ? _monthLabel(snapshot.mostActiveMonth!) : '—',
            ),
          ];

          return SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: AppTheme.primary),
                  ),
                ),
                Expanded(
                  child: PageView(controller: _pageController, children: cards),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _wrappedCard(int index, String title, String body) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Expanded(
            child: RepaintBoundary(
              key: _cardKeys[index],
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  gradient: AppTheme.gradientLiked,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      body.isEmpty ? '—' : body,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _isSharing ? null : () => _share(index),
            icon: Icon(AppIcons.broken(SolarIcons.Share), size: 18),
            label: const Text('Compartir'),
          ),
        ],
      ),
    );
  }

  String _monthLabel(DateTime month) {
    const names = [
      'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
    ];
    return '${names[month.month - 1]} ${month.year}';
  }
}
