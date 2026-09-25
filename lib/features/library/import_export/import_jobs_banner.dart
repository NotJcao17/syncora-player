import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import 'import_manager.dart';
import 'playlist_import_export_service.dart';

/// Tarjetas de progreso de las importaciones en segundo plano (ronda 4).
///
/// Con [playlistId] muestra solo la de esa playlist (vista de detalle); sin
/// él, todas (Biblioteca).
class ImportJobsBanner extends ConsumerWidget {
  const ImportJobsBanner({super.key, this.playlistId, this.padding = EdgeInsets.zero});

  final int? playlistId;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(importManagerProvider).where((j) {
      if (j.status == ImportJobStatus.cancelled) return false;
      return playlistId == null || j.playlistId == playlistId;
    }).toList();
    if (jobs.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [for (final job in jobs) _ImportJobCard(job: job, showOpen: playlistId == null)],
      ),
    );
  }
}

class _ImportJobCard extends ConsumerWidget {
  const _ImportJobCard({required this.job, required this.showOpen});

  final ImportJob job;
  final bool showOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.read(importManagerProvider.notifier);
    final done = job.status == ImportJobStatus.completed;
    final paused = job.status == ImportJobStatus.paused;

    final String statusText;
    if (done) {
      statusText = job.unmatched.isEmpty
          ? 'Completada: ${job.matchedCount} canciones'
          : 'Completada: ${job.matchedCount} encontradas, ${job.unmatched.length} no encontradas';
    } else if (paused) {
      statusText = 'En pausa (${job.pauseReason ?? 'detenida'}) · ${job.nextIndex} de ${job.total}';
    } else {
      statusText = 'Importando ${job.nextIndex} de ${job.total} · puedes seguir usando la app';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.surfaceHover),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                done ? AppIcons.bold(SolarIcons.CheckCircle) : AppIcons.broken(SolarIcons.Import),
                color: done ? AppTheme.accent : AppTheme.primary,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusText,
                      maxLines: 2,
                      style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (showOpen)
                IconButton(
                  tooltip: 'Abrir playlist',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary, size: 18),
                  onPressed: () => context.push('/playlist/${job.playlistId}'),
                ),
              if (done)
                IconButton(
                  tooltip: 'Cerrar',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary, size: 18),
                  onPressed: () => manager.dismiss(job.id),
                ),
            ],
          ),
          if (!done) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: job.ratio,
                  minHeight: 4,
                  backgroundColor: AppTheme.surfaceHover,
                  color: paused ? AppTheme.muted : AppTheme.primary,
                ),
              ),
            ),
          ],
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              if (done && job.unmatched.isNotEmpty)
                TextButton(
                  onPressed: () => _showUnmatched(context, job.unmatched),
                  child: const Text('Ver no encontradas', style: TextStyle(color: AppTheme.primary, fontSize: 12)),
                ),
              if (paused)
                TextButton(
                  onPressed: () => manager.resume(job.id),
                  child: const Text('Reanudar', style: TextStyle(color: AppTheme.primary, fontSize: 12)),
                ),
              if (!done)
                TextButton(
                  onPressed: () => _confirmCancel(context, manager),
                  child: const Text('Cancelar', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCancel(BuildContext context, ImportManager manager) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('¿Detener la importación?', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        content: Text(
          'Ya se importaron ${job.matchedCount} canciones a "${job.title}".',
          style: const TextStyle(color: AppTheme.secondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Seguir importando', style: TextStyle(color: AppTheme.secondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('Detener y conservar', style: TextStyle(color: AppTheme.primary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('Cancelar y borrar la playlist', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await manager.cancel(job.id, deletePlaylist: choice == 'delete');
  }

  void _showUnmatched(BuildContext context, List<RawImportTrack> unmatched) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '${unmatched.length} no encontradas',
          style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: 420,
          height: 360,
          child: ListView.builder(
            itemCount: unmatched.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                unmatched[i].toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTheme.primary, fontSize: 12),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar', style: TextStyle(color: AppTheme.primary)),
          ),
        ],
      ),
    );
  }
}
