import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../player/player_models.dart';

import '../download_provider.dart';
import '../download_service.dart';

enum DownloadButtonState { none, partial, complete }

class DownloadHeaderButton extends ConsumerStatefulWidget {
  final String title;
  final List<SyncoraTrack> tracks;

  /// Paso previo obligatorio antes de abrir las opciones de descarga.
  ///
  /// Lo usan las colecciones que todavía no están en la biblioteca (playlists
  /// de Deezer, mixes): descargarlas guarda primero una copia, para que las
  /// pistas descargadas siempre cuelguen de algo que el usuario puede
  /// encontrar. Si devuelve `false`, la descarga no sigue.
  final Future<bool> Function()? onBeforeDownload;

  const DownloadHeaderButton({
    super.key,
    required this.title,
    required this.tracks,
    this.onBeforeDownload,
  });

  @override
  ConsumerState<DownloadHeaderButton> createState() => _DownloadHeaderButtonState();
}

class _DownloadHeaderButtonState extends ConsumerState<DownloadHeaderButton> {
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    if (widget.tracks.isEmpty) return const SizedBox.shrink();

    final downloadedTracksAsync = ref.watch(watchAllDownloadedTracksProvider);
    final downloadedTracks = downloadedTracksAsync.value ?? [];
    final downloadedIds = downloadedTracks.map((DownloadedTrack t) => t.trackId).toSet();


    final totalCount = widget.tracks.length;
    int downloadedCount = 0;
    for (final t in widget.tracks) {
      final tId = int.tryParse(t.id) ?? t.id.hashCode.abs();
      if (downloadedIds.contains(tId)) {
        downloadedCount++;
      }
    }


    final DownloadButtonState buttonState;
    if (downloadedCount == 0) {
      buttonState = DownloadButtonState.none;
    } else if (downloadedCount == totalCount) {
      buttonState = DownloadButtonState.complete;
    } else {
      buttonState = DownloadButtonState.partial;
    }

    Widget iconWidget;
    switch (buttonState) {
      case DownloadButtonState.none:
        iconWidget = Icon(
          AppIcons.broken(SolarIcons.CloudDownload),
          color: AppTheme.primary,
          size: 22,
        );
        break;
      case DownloadButtonState.partial:
        // Ronda 4: el `Badge` de Material crece hacia la derecha desde la
        // esquina, así que "35/39" ya se metía debajo del botón de al lado y
        // "900/1000" no cabía. Ahora la etiqueta va centrada sobre el ícono,
        // dentro del área del propio botón, y a partir de 100 canciones se
        // muestra como porcentaje para no pasar de 4 caracteres.
        final label = totalCount >= 100
            ? '${(downloadedCount * 100 / totalCount).floor()}%'
            : '$downloadedCount/$totalCount';
        iconWidget = SizedBox(
          width: 34,
          height: 30,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(
                AppIcons.broken(SolarIcons.CloudDownload),
                color: AppTheme.primary,
                size: 22,
              ),
              Positioned(
                bottom: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 9,
                      height: 1.1,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
        break;
      case DownloadButtonState.complete:
        iconWidget = Icon(
          AppIcons.bold(SolarIcons.CloudCheck),
          color: AppTheme.primary,
          size: 22,
        );
        break;
    }

    if (_isProcessing) {
      iconWidget = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppTheme.primary,
        ),
      );
    }

    return IconButton(
      icon: iconWidget,
      onPressed: _isProcessing
          ? null
          : () async {
              final before = widget.onBeforeDownload;
              if (before != null) {
                setState(() => _isProcessing = true);
                bool canContinue;
                try {
                  canContinue = await before();
                } catch (_) {
                  canContinue = false;
                } finally {
                  if (mounted) setState(() => _isProcessing = false);
                }
                if (!canContinue || !mounted) return;
              }
              if (!context.mounted) return;
              _showDownloadBottomSheet(context, buttonState, downloadedCount, totalCount);
            },
      tooltip: 'Opciones de descarga',
    );
  }

  void _showDownloadBottomSheet(
    BuildContext context,
    DownloadButtonState state,
    int downloadedCount,
    int totalCount,
  ) {
    final downloadService = ref.read(downloadServiceProvider);
    final dao = ref.read(downloadedTrackDaoProvider);

    AppBottomSheet.show(
      context: context,
      title: switch (state) {
        DownloadButtonState.none => 'Descargar "${widget.title}"',
        DownloadButtonState.partial => 'Descargas parciales ($downloadedCount de $totalCount)',
        DownloadButtonState.complete => '"${widget.title}" descargada',
      },
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (state == DownloadButtonState.none) ...[
            ListTile(
              leading: Icon(AppIcons.broken(SolarIcons.CloudDownload), color: AppTheme.primary),
              title: Text('Descargar todo ($totalCount canciones)', style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
              onTap: () {
                AppBottomSheet.pop(context);
                _startDownload(downloadService, widget.tracks);
              },
            ),
          ] else if (state == DownloadButtonState.partial) ...[
            ListTile(
              leading: Icon(AppIcons.broken(SolarIcons.CloudDownload), color: AppTheme.primary),
              title: Text('Descargar ${totalCount - downloadedCount} faltantes', style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
              onTap: () {
                AppBottomSheet.pop(context);
                _startDownload(downloadService, widget.tracks);
              },
            ),
            ListTile(
              leading: Icon(AppIcons.broken(SolarIcons.TrashBinTrash), color: Colors.redAccent),
              title: const Text('Eliminar descargas existentes', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
              onTap: () {
                AppBottomSheet.pop(context);
                _confirmAndDelete(dao);
              },
            ),
          ] else ...[
            ListTile(
              leading: Icon(AppIcons.broken(SolarIcons.Restart), color: AppTheme.primary),
              title: const Text('Verificar y actualizar descargas', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
              onTap: () {
                AppBottomSheet.pop(context);
                _startDownload(downloadService, widget.tracks);
              },
            ),
            ListTile(
              leading: Icon(AppIcons.broken(SolarIcons.TrashBinTrash), color: Colors.redAccent),
              title: const Text('Eliminar todas las descargas', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
              onTap: () {
                AppBottomSheet.pop(context);
                _confirmAndDelete(dao);
              },
            ),
          ],
        ],
      ),
    );
  }

  void _confirmAndDelete(dynamic dao) {
    AppBottomSheet.show(
      context: context,
      title: 'Eliminar descargas localmente',
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '¿Deseas eliminar los archivos de audio locales de este dispositivo?',
              style: TextStyle(color: AppTheme.secondary, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => AppBottomSheet.pop(context),
                    child: const Text('Cancelar', style: TextStyle(color: AppTheme.primary)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                    onPressed: () async {
                      AppBottomSheet.pop(context);
                      for (final t in widget.tracks) {

                        final tId = int.tryParse(t.id) ?? t.id.hashCode.abs();

                        await dao.deleteByTrackId(tId);
                      }

                      if (mounted) {
                        AppToast.show(context, message: 'Descargas eliminadas del dispositivo');
                      }
                    },
                    child: const Text('Eliminar', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _startDownload(DownloadService service, List<SyncoraTrack> tracks) async {
    setState(() => _isProcessing = true);
    try {
      final downloadedTracksAsync = ref.read(watchAllDownloadedTracksProvider);
      final downloadedTracks = downloadedTracksAsync.value ?? [];
      final downloadedIds = downloadedTracks
          .where((DownloadedTrack t) => t.downloadState == 2)
          .map((DownloadedTrack t) => t.trackId)
          .toSet();

      final pendingCount = tracks.where((t) {
        final tId = int.tryParse(t.id) ?? t.id.hashCode.abs();
        return !downloadedIds.contains(tId);
      }).length;

      if (pendingCount == 0) {
        AppToast.show(context, message: 'Todas las canciones ya están descargadas');
        return;
      }

      final startMessage = pendingCount == 1
          ? 'Descargando 1 canción...'
          : 'Descargando $pendingCount canciones...';
      AppToast.show(context, message: startMessage);

      final result = await service.downloadTracks(tracks, groupLabel: widget.title);
      if (mounted) {
        if (result.failedCount == 0) {
          AppToast.show(context, message: 'Descarga completada');
        } else if (result.successCount == 0) {
          final errorText = result.errors.isNotEmpty ? result.errors.first : 'Error en la descarga';
          AppToast.show(context, message: errorText);
        } else {
          AppToast.show(
            context,
            message: 'Descargadas ${result.successCount}/${tracks.length}. Fallaron ${result.failedCount}',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, message: ErrorStateWidget.formatErrorMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }
}
