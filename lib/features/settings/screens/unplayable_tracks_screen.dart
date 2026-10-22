import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_state.dart';
import '../../player/unplayable_track_log.dart';

/// Configuración → Reproducción → "No se pudieron reproducir" (ronda 10).
///
/// Las canciones que la app saltó o dejó en pausa porque no se pudieron
/// reproducir, con el motivo y la hora. Sirve para entender un salto ("¿por
/// qué no sonó esa?") y para ver si un fallo coincide con datos móviles.
class UnplayableTracksScreen extends ConsumerWidget {
  const UnplayableTracksScreen({super.key});

  static const _months = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

  static String formatWhen(DateTime at, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final hour = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final sameDay = at.year == today.year && at.month == today.month && at.day == today.day;
    if (sameDay) return 'Hoy a las $hour';
    final yesterday = today.subtract(const Duration(days: 1));
    if (at.year == yesterday.year && at.month == yesterday.month && at.day == yesterday.day) {
      return 'Ayer a las $hour';
    }
    return '${at.day} ${_months[at.month - 1]}, $hour';
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '¿Borrar el registro?',
          style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Solo se borra esta lista; las canciones no cambian.',
          style: TextStyle(color: AppTheme.secondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm == true) ref.read(unplayableTrackLogProvider).clear();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(unplayableTrackLogProvider).entries;
    final isDesktop = MediaQuery.sizeOf(context).width >= 768;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        elevation: 0,
        title: const Text(
          'No se pudieron reproducir',
          style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              icon: Icon(AppIcons.broken(SolarIcons.TrashBinMinimalistic), color: AppTheme.secondary),
              tooltip: 'Borrar registro',
              onPressed: () => _confirmClear(context, ref),
            ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: EmptyStateWidget(
                title: 'Todo se pudo reproducir',
                message: 'Si una canción no se puede reproducir, aparecerá aquí con la hora y el motivo.',
              ),
            )
          : ListView.separated(
              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 16, vertical: 12),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(AppIcons.broken(SolarIcons.DangerCircle), color: AppTheme.muted, size: 22),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                            if (entry.artist.isNotEmpty)
                              Text(
                                entry.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
                              ),
                            const SizedBox(height: 4),
                            Text(
                              '${entry.reason} · ${formatWhen(entry.at)}',
                              style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
