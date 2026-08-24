import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../player/player_providers.dart';

final recentListeningHistoryProvider = StreamProvider<List<ListeningHistoryData>>((ref) {
  final dao = ref.watch(listeningHistoryDaoProvider);
  return dao.watchRecentHistory(limit: 100);
});

class ResolvedHistoryItem {
  final ListeningHistoryData data;
  final DeezerTrack? track;

  const ResolvedHistoryItem({required this.data, this.track});
}

final resolvedListeningHistoryProvider = FutureProvider<List<ResolvedHistoryItem>>((ref) async {
  final historyAsync = ref.watch(recentListeningHistoryProvider);
  final entries = historyAsync.value ?? [];
  if (entries.isEmpty) return const [];

  final deezerApi = ref.watch(deezerApiProvider);
  final uniqueTrackIds = entries.map((e) => e.trackId).where((id) => id > 0).toSet();

  final trackMap = <int, DeezerTrack>{};
  await Future.wait(uniqueTrackIds.map((trackId) async {
    try {
      final track = await deezerApi.getTrack(trackId);
      trackMap[trackId] = track;
    } catch (_) {}
  }));

  return entries.map((e) => ResolvedHistoryItem(data: e, track: trackMap[e.trackId])).toList();
});

class ListeningHistoryScreen extends ConsumerWidget {
  const ListeningHistoryScreen({super.key});

  String _formatTimeAgo(DateTime dt) {
    final now = DateTime.now();
    final difference = now.difference(dt);

    if (difference.inMinutes < 1) {
      return 'Hace un momento';
    } else if (difference.inMinutes < 60) {
      return 'Hace ${difference.inMinutes} min';
    } else if (difference.inHours < 24 && now.day == dt.day) {
      final hour = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return 'Hoy a las $hour:$min';
    } else if (difference.inDays < 2 || (now.day - dt.day == 1 && difference.inHours < 48)) {
      final hour = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return 'Ayer a las $hour:$min';
    } else {
      final months = [
        'ene', 'feb', 'mar', 'abr', 'may', 'jun',
        'jul', 'ago', 'sep', 'oct', 'nov', 'dic'
      ];
      final month = months[dt.month - 1];
      final hour = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return '${dt.day} $month, $hour:$min';
    }
  }

  Future<void> _confirmClearHistory(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '¿Borrar historial de reproducción?',
          style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Se eliminará el registro de canciones escuchadas localmente.',
          style: TextStyle(color: AppTheme.secondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final dao = ref.read(listeningHistoryDaoProvider);
      await dao.deleteAll();
      if (context.mounted) {
        AppToast.show(context, message: 'Historial de reproducción eliminado.');
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(resolvedListeningHistoryProvider);
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        elevation: 0,
        title: const Text(
          'Historial de reproducción',
          style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: Icon(AppIcons.broken(SolarIcons.TrashBinMinimalistic), color: AppTheme.secondary),
            tooltip: 'Borrar historial',
            onPressed: () => _confirmClearHistory(context, ref),
          ),
        ],
      ),
      body: historyAsync.when(
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: EmptyStateWidget(
                title: 'Sin canciones reproducidas',
                message: 'Las canciones que escuches se guardarán automáticamente en tu historial.',
              ),
            );
          }

          return ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 16, vertical: 12),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (ctx, index) {
              final item = items[index];
              final track = item.track;
              final timeAgo = _formatTimeAgo(item.data.listenedAt);

              if (track == null) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceHover,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 20),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Canción #${item.data.trackId}',
                              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              timeAgo,
                              style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: CachedNetworkImage(
                          imageUrl: track.coverUrl,
                          memCacheWidth: 200,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => Container(
                            color: AppTheme.surfaceHover,
                            child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 20),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 14),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  track.artistName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                timeAgo,
                                style: TextStyle(
                                  color: AppTheme.secondary.withValues(alpha: 0.75),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(AppIcons.broken(SolarIcons.Play), color: AppTheme.primary, size: 20),
                      onPressed: () {
                        final controller = ref.read(syncoraPlayerControllerProvider.notifier);
                        controller.setQueue([track.toSyncoraTrack()], startIndex: 0);
                        controller.play();
                      },
                      tooltip: 'Reproducir',
                    ),
                  ],
                ),
              );
            },
          );
        },
        loading: () => ListView.separated(
          padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 16, vertical: 12),
          itemCount: 8,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, _) => const SkeletonBox(height: 60, borderRadius: 12),
        ),
        error: (err, _) => Center(
          child: EmptyStateWidget(
            title: 'Error al cargar el historial',
            message: err.toString(),
          ),
        ),
      ),
    );
  }
}
