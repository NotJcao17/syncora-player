import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/updates/app_update_service.dart';
import '../../../core/updates/app_update_sheet.dart';
import '../../../core/widgets/app_toast.dart';

/// "Buscar actualizaciones" en Configuración. A diferencia del aviso al abrir
/// la app, consulta siempre y ofrece también una versión que se omitió.
class CheckUpdatesTile extends ConsumerStatefulWidget {
  const CheckUpdatesTile({super.key});

  @override
  ConsumerState<CheckUpdatesTile> createState() => _CheckUpdatesTileState();
}

class _CheckUpdatesTileState extends ConsumerState<CheckUpdatesTile> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final update = await ref.read(appUpdateServiceProvider).check();
      if (!mounted) return;
      if (update == null) {
        AppToast.show(context, message: 'Ya tienes la última versión');
      } else {
        await showAppUpdateSheet(context, update);
      }
    } catch (_) {
      if (mounted) AppToast.show(context, message: 'No se pudo buscar actualizaciones. Revisa tu conexión.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _check,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(AppIcons.broken(SolarIcons.Refresh), color: AppTheme.primary, size: 22),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Buscar actualizaciones',
                    style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Descarga e instala la versión nueva desde la app',
                    style: TextStyle(color: AppTheme.secondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (_checking)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.secondary),
              )
            else
              Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary, size: 18),
          ],
        ),
      ),
    );
  }
}
