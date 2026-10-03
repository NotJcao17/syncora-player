import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extraction/engine/engine_bundle.dart';
import '../../../core/extraction/engine/engine_manager.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';

/// Configuración → Motor de reproducción (Fase 8).
///
/// Muestra qué motor de extracción está en uso, si está sano, y permite
/// buscar una actualización a mano. Las actualizaciones normales son
/// automáticas y silenciosas: esta tarjeta existe para entender qué pasa
/// cuando algo falla, no para que el usuario tenga que gestionarlo.
class EngineStatusSection extends ConsumerStatefulWidget {
  const EngineStatusSection({super.key, required this.manager});

  final EngineManager manager;

  @override
  ConsumerState<EngineStatusSection> createState() => _EngineStatusSectionState();
}

class _EngineStatusSectionState extends ConsumerState<EngineStatusSection> {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    widget.manager.refreshStatus();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final result = await widget.manager.checkForUpdates(force: true);
    if (!mounted) return;
    setState(() => _checking = false);
    final message = switch (result.outcome) {
      EngineCheckOutcome.downloaded =>
        'Versión ${formatEngineBuild(result.build!)} descargada. Se usará sola si la actual falla.',
      EngineCheckOutcome.upToDate => 'No hay una versión más nueva del motor.',
      EngineCheckOutcome.failed => 'No se pudo comprobar. Revisa tu conexión.',
      EngineCheckOutcome.disabled => 'Las actualizaciones del motor no están configuradas en esta compilación.',
      EngineCheckOutcome.throttled => 'Ya se está comprobando.',
    };
    AppToast.show(context, message: message);
  }

  Future<void> _adopt(int build) async {
    await widget.manager.adoptOnNextLaunch(build);
    if (!mounted) return;
    AppToast.show(context, message: 'Se usará la versión ${formatEngineBuild(build)} al reiniciar la app.');
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EngineStatus>(
      valueListenable: widget.manager.status,
      builder: (context, status, _) {
        final info = status.info;
        final (label, color) = switch (status.health) {
          EngineHealth.ok => ('Funcionando', const Color(0xFF4ADE80)),
          EngineHealth.broken => ('Con fallos', const Color(0xFFFBBF24)),
          EngineHealth.recovering => ('Buscando arreglo…', const Color(0xFFFBBF24)),
          EngineHealth.noFix => ('Sin arreglo todavía', Colors.redAccent),
        };
        final origin = status.source == EngineSource.downloaded ? 'actualización' : 'de fábrica';
        final standby = status.standbyBuild;
        final adopt = status.adoptOnNextLaunch;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(AppIcons.broken(SolarIcons.ServerSquare), color: AppTheme.primary, size: 22),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Motor de YouTube',
                        style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        info == null
                            ? 'Cargando…'
                            : 'Versión ${formatEngineBuild(info.build)} · $origin'
                                '${info.youtubei != null ? ' · youtubei.js ${info.youtubei}' : ''}',
                        style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                _StatusPill(label: label, color: color),
              ],
            ),
            if (status.loadError != null) ...[
              const SizedBox(height: 8),
              Text(
                status.loadError!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              !status.otaConfigured
                  ? 'Las actualizaciones automáticas del motor no están activadas en esta compilación.'
                  : status.lastCheckAt == null
                      ? 'Se actualiza solo cuando YouTube cambia algo. Todavía no se ha comprobado.'
                      : 'Se actualiza solo cuando YouTube cambia algo. '
                          'Última comprobación: ${_relative(status.lastCheckAt!)}.',
              style: const TextStyle(color: AppTheme.secondary, fontSize: 12, height: 1.4),
            ),
            if (adopt != null) ...[
              const SizedBox(height: 8),
              Text(
                'La versión ${formatEngineBuild(adopt)} se usará al reiniciar la app.',
                style: const TextStyle(color: AppTheme.primary, fontSize: 12),
              ),
            ] else if (standby != null) ...[
              const SizedBox(height: 8),
              Text(
                'Versión ${formatEngineBuild(standby)} descargada: se usará sola si la actual falla.',
                style: const TextStyle(color: AppTheme.primary, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: status.otaConfigured && !_checking ? _check : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: const BorderSide(color: AppTheme.surfaceActive),
                    minimumSize: const Size(0, 40),
                  ),
                  child: Text(_checking ? 'Comprobando…' : 'Buscar actualización'),
                ),
                if (standby != null && adopt == null)
                  TextButton(
                    onPressed: () => _adopt(standby),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.secondary,
                      minimumSize: const Size(0, 40),
                    ),
                    child: const Text('Usarla al reiniciar'),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  static String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'hace un momento';
    if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
    if (d.inHours < 24) return 'hace ${d.inHours} h';
    return 'hace ${d.inDays} d';
  }
}

/// `202610021530` (AAAAMMDDHHmm UTC) → `2026.10.02-1530`.
String formatEngineBuild(int build) {
  final s = build.toString();
  if (s.length != 12) return s;
  return '${s.substring(0, 4)}.${s.substring(4, 6)}.${s.substring(6, 8)}-${s.substring(8)}';
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
