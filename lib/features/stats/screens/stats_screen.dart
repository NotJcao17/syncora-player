import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../../data/sync/sync_cache_manager.dart';
import '../../../data/sync/sync_service.dart';
import '../../auth/local_mode_provider.dart';
import '../genre_backfill_service.dart';
import '../stats_models.dart';
import '../stats_providers.dart';
import '../widgets/habits_heatmap.dart';
import '../widgets/listening_chart.dart';
import '../widgets/stats_cards.dart';
import 'wrapped_screen.dart';

/// Pantalla de Estadísticas (`/stats`), rediseñada como dashboard.
///
/// Sustituye a las tres pestañas fijas (Semanal / Mensual / Anual) por un
/// **selector de periodo** del que cuelga todo lo demás: al cambiarlo se
/// recalculan las cifras, el gráfico, los tops y el mapa de hábitos, y el
/// gráfico reagrupa solo (por día en 7 y 30 días, por semana en 3 meses,
/// por mes en las ventanas largas).
///
/// En modo local (7.I.6) los periodos largos se ocultan: dependen de
/// `user_stats_monthly`, que solo existe en la nube.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  @override
  void initState() {
    super.initState();
    _autoRefreshIfStale();
  }

  /// Inicio y Biblioteca ya se refrescan solos al volver tras ≥5 min
  /// (`SyncCacheManager`). Estadísticas no tenía nada equivalente y dependía
  /// del botón manual. Clave propia 'stats' para no pisar el TTL de
  /// 'library'/'saved_albums'.
  void _autoRefreshIfStale() {
    final cacheManager = ref.read(syncCacheManagerProvider);
    if (!cacheManager.isExpired('stats')) return;
    cacheManager.markSynced('stats');
    Future.microtask(_refresh);
  }

  Future<void> _refresh() async {
    if (!ref.read(localModeProvider)) {
      await ref.read(syncServiceProvider).syncListeningHistory();
    }
    // Aprovecha la visita para avanzar el relleno de géneros: es la pantalla
    // donde el usuario los echa en falta.
    await ref.read(genreBackfillServiceProvider).run();
    if (!mounted) return;
    ref.invalidate(statsSnapshotProvider);
  }

  @override
  Widget build(BuildContext context) {
    final isLocalMode = ref.watch(localModeProvider);
    final period = ref.watch(selectedStatsPeriodProvider);
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          color: AppTheme.accent,
          backgroundColor: AppTheme.surface,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _Header(
                  onRefresh: _refresh,
                  onWrapped: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => WrappedScreen(period: period)),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _PeriodSelector(
                  selected: period,
                  isLocalMode: isLocalMode,
                  onChanged: (p) =>
                      ref.read(selectedStatsPeriodProvider.notifier).state = p,
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, isDesktop ? 32 : 120),
                sliver: _Dashboard(period: period, isDesktop: isDesktop),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onRefresh;
  final VoidCallback onWrapped;

  const _Header({required this.onRefresh, required this.onWrapped});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Tus estadísticas',
              style: TextStyle(
                color: AppTheme.primary,
                fontSize: 26,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Actualizar',
            onPressed: onRefresh,
            icon: Icon(AppIcons.broken(SolarIcons.Refresh), color: AppTheme.secondary),
          ),
          FilledButton.icon(
            onPressed: onWrapped,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('Wrapped'),
          ),
        ],
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  final StatsPeriod selected;
  final bool isLocalMode;
  final ValueChanged<StatsPeriod> onChanged;

  const _PeriodSelector({
    required this.selected,
    required this.isLocalMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Sin cuenta no hay agregado mensual, así que las ventanas largas se
    // ocultan en vez de mostrarse deshabilitadas (criterio de 7.I.6).
    final periods = StatsPeriod.values
        .where((p) => !isLocalMode || !p.usesMonthlyAggregate)
        .toList();

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: periods.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final p = periods[i];
          final isSelected = p == selected;
          return Center(
            child: GestureDetector(
              onTap: () => onChanged(p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? AppTheme.accent : AppTheme.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? AppTheme.accent
                        : Colors.white.withValues(alpha: 0.07),
                  ),
                ),
                child: Text(
                  p.label,
                  style: TextStyle(
                    color: isSelected ? Colors.white : AppTheme.secondary,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Dashboard extends ConsumerWidget {
  final StatsPeriod period;
  final bool isDesktop;

  const _Dashboard({required this.period, required this.isDesktop});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(statsSnapshotProvider(period));

    return async.when(
      loading: () => const SliverToBoxAdapter(child: _LoadingSkeleton()),
      error: (e, _) => SliverToBoxAdapter(child: _ErrorState(onRetry: () {
        ref.invalidate(statsSnapshotProvider(period));
      })),
      data: (snapshot) {
        if (snapshot.isEmpty) {
          return const SliverToBoxAdapter(child: _EmptyState());
        }
        return SliverToBoxAdapter(
          child: _DashboardBody(snapshot: snapshot, period: period, isDesktop: isDesktop),
        );
      },
    );
  }
}

class _DashboardBody extends ConsumerStatefulWidget {
  final StatsSnapshot snapshot;
  final StatsPeriod period;
  final bool isDesktop;

  const _DashboardBody({
    required this.snapshot,
    required this.period,
    required this.isDesktop,
  });

  @override
  ConsumerState<_DashboardBody> createState() => _DashboardBodyState();
}

class _DashboardBodyState extends ConsumerState<_DashboardBody> {
  /// Cuántos elementos se muestran en cada top. Empieza en 5 y crece con
  /// "Mostrar más" — ver 25 de entrada es una pared de texto.
  static const _initialTop = 5;
  static const _expandedTop = 25;

  bool _artistsExpanded = false;
  bool _tracksExpanded = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final artistEntries = s.topArtists.take(_artistsExpanded ? _expandedTop : _initialTop).toList();
    final trackEntries = s.topTracks.take(_tracksExpanded ? _expandedTop : _initialTop).toList();

    final artistsAsync = ref.watch(enrichedArtistsProvider(artistEntries));
    final tracksAsync = ref.watch(enrichedTracksProvider(trackEntries));

    final chart = StatsPanel(
      title: 'Minutos escuchados',
      subtitle: _chartSubtitle(widget.period),
      child: ListeningChart(series: s.series, bucket: widget.period.bucket),
    );

    final artists = StatsPanel(
      title: 'Tus artistas',
      subtitle: s.topsAreApproximate ? 'Aproximado en periodos largos' : null,
      action: s.topArtists.length > _initialTop
          ? _MoreButton(
              expanded: _artistsExpanded,
              onTap: () => setState(() => _artistsExpanded = !_artistsExpanded),
            )
          : null,
      child: artistsAsync.when(
        loading: () => const _RowsSkeleton(),
        error: (_, _) => const _PanelError(),
        data: (list) => TopArtistsPodium(artists: list, totalMs: s.totalMs),
      ),
    );

    final tracks = StatsPanel(
      title: 'Tus canciones',
      subtitle: s.topsAreApproximate ? 'Aproximado en periodos largos' : null,
      action: s.topTracks.length > _initialTop
          ? _MoreButton(
              expanded: _tracksExpanded,
              onTap: () => setState(() => _tracksExpanded = !_tracksExpanded),
            )
          : null,
      child: tracksAsync.when(
        loading: () => const _RowsSkeleton(),
        error: (_, _) => const _PanelError(),
        data: (list) => TopTracksList(tracks: list),
      ),
    );

    final genres = StatsPanel(
      title: 'Tus géneros',
      child: GenreBars(genres: s.topGenres),
    );

    final habits = StatsPanel(
      title: 'Cuándo escuchas',
      subtitle: 'Por día de la semana y franja horaria',
      child: HabitsHeatmap(cells: s.hours),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _KpiGrid(snapshot: s, period: widget.period, isDesktop: widget.isDesktop),
        const SizedBox(height: 12),
        chart,
        const SizedBox(height: 12),
        // En escritorio el dashboard va a dos columnas; en móvil, una sola
        // columna con scroll.
        if (widget.isDesktop)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Column(children: [artists, const SizedBox(height: 12), genres])),
                const SizedBox(width: 12),
                Expanded(child: Column(children: [tracks, const SizedBox(height: 12), habits])),
              ],
            ),
          )
        else ...[
          artists,
          const SizedBox(height: 12),
          tracks,
          const SizedBox(height: 12),
          genres,
          const SizedBox(height: 12),
          habits,
        ],
      ],
    );
  }

  static String _chartSubtitle(StatsPeriod period) => switch (period.bucket) {
        StatsBucket.day => 'Por día',
        StatsBucket.week => 'Por semana',
        StatsBucket.month => 'Por mes',
      };
}

class _KpiGrid extends StatelessWidget {
  final StatsSnapshot snapshot;
  final StatsPeriod period;
  final bool isDesktop;

  const _KpiGrid({required this.snapshot, required this.period, required this.isDesktop});

  @override
  Widget build(BuildContext context) {
    final tiles = [
      KpiTile(
        label: 'Tiempo escuchado',
        value: formatListeningTime(snapshot.totalMs),
        icon: Icons.schedule,
        trend: snapshot.trend,
      ),
      KpiTile(
        label: 'Reproducciones',
        value: '${snapshot.totalPlays}',
        icon: Icons.play_arrow_rounded,
      ),
      KpiTile(
        label: 'Artistas',
        value: '${snapshot.distinctArtists}',
        icon: Icons.person_outline,
      ),
      KpiTile(
        label: snapshot.activeDays > 0 ? 'Días con música' : 'Canciones',
        value: snapshot.activeDays > 0
            ? '${snapshot.activeDays}'
            : '${snapshot.distinctTracks}',
        icon: snapshot.activeDays > 0 ? Icons.calendar_today_outlined : Icons.music_note_outlined,
      ),
    ];

    return GridView.count(
      crossAxisCount: isDesktop ? 4 : 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: isDesktop ? 2.1 : 1.55,
      children: tiles,
    );
  }
}

class _MoreButton extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _MoreButton({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: AppTheme.accent,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(expanded ? 'Ver menos' : 'Ver más', style: const TextStyle(fontSize: 12)),
    );
  }
}

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: SkeletonBox(height: 92)),
            SizedBox(width: 12),
            Expanded(child: SkeletonBox(height: 92)),
          ]),
          SizedBox(height: 12),
          SkeletonBox(height: 240),
          SizedBox(height: 12),
          SkeletonBox(height: 200),
        ],
      ),
    );
  }
}

class _RowsSkeleton extends StatelessWidget {
  const _RowsSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        SkeletonBox(height: 40),
        SizedBox(height: 8),
        SkeletonBox(height: 40),
        SizedBox(height: 8),
        SkeletonBox(height: 40),
      ],
    );
  }
}

class _PanelError extends StatelessWidget {
  const _PanelError();

  @override
  Widget build(BuildContext context) => const Text(
        'No se pudo cargar esta sección.',
        style: TextStyle(color: AppTheme.muted, fontSize: 12),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
      child: Column(
        children: [
          Icon(AppIcons.broken(SolarIcons.ChartSquare), size: 48, color: AppTheme.muted),
          const SizedBox(height: 16),
          const Text(
            'Todavía no hay nada que contar',
            style: TextStyle(
              color: AppTheme.primary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Escucha algo de música y tus estadísticas de este periodo '
            'aparecerán aquí.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
      child: Column(
        children: [
          const Text(
            'No se pudieron cargar tus estadísticas',
            style: TextStyle(color: AppTheme.primary, fontSize: 15),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Reintentar')),
        ],
      ),
    );
  }
}
