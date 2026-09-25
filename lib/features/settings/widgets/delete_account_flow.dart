import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../data/local_db/database_provider.dart';
import '../../auth/services/local_library_wipe.dart';

/// Palabra que hay que escribir para habilitar el borrado.
const _confirmWord = 'ELIMINAR';

/// Eliminar la cuenta con confirmación fuerte (ronda 4).
///
/// Dos pasos: un diálogo que explica exactamente qué se borra y exige
/// escribir [_confirmWord], y después la llamada a la RPC `delete_my_account`
/// (migración `20250001000018`), que borra al usuario de `auth.users` y, en
/// cascada, todo lo suyo en la nube. Solo si la nube confirma se limpia la
/// biblioteca local y se cierra la sesión; las descargas se conservan.
Future<void> showDeleteAccountFlow(BuildContext context, WidgetRef ref) async {
  if (!(ref.read(isConnectedProvider).value ?? true)) {
    AppToast.show(context, message: 'Sin conexión. Para eliminar tu cuenta necesitas internet.');
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => const _DeleteAccountDialog(),
  );
  if (confirmed != true || !context.mounted) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
    ),
  );

  final dao = ref.read(playlistDaoProvider);
  final savedAlbumDao = ref.read(savedAlbumDaoProvider);
  final historyDao = ref.read(listeningHistoryDaoProvider);
  final router = GoRouter.of(context);
  final rootNavigator = Navigator.of(context, rootNavigator: true);

  try {
    await Supabase.instance.client.rpc('delete_my_account');
  } catch (e) {
    rootNavigator.pop();
    if (context.mounted) {
      AppToast.show(context, message: 'No se pudo eliminar la cuenta. Intenta de nuevo más tarde.');
    }
    return;
  }

  // Se cierra el indicador y se avisa ANTES de cerrar sesión: al hacerlo, el
  // router saca al usuario de Configuración y este `context` deja de valer.
  rootNavigator.pop();
  if (context.mounted) {
    AppToast.show(context, message: 'Tu cuenta y tus datos en la nube se eliminaron.');
  }

  try {
    await wipeLocalLibrary(dao: dao, savedAlbumDao: savedAlbumDao, historyDao: historyDao);
  } catch (_) {
    // La cuenta ya no existe: lo local que no se pudo borrar queda sin
    // `remoteId` útil, un estado ya soportado.
  }
  try {
    await Supabase.instance.client.auth.signOut();
  } catch (_) {
    // El usuario ya no existe en el servidor; la sesión local se descarta igual.
  }
  router.go('/auth');
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canDelete = _controller.text.trim().toUpperCase() == _confirmWord;
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('¿Eliminar tu cuenta?', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Esto borra de forma permanente, en la nube y en este dispositivo:',
                style: TextStyle(color: AppTheme.primary, fontSize: 14),
              ),
              const SizedBox(height: 8),
              const Text(
                '• Todas tus playlists y "Tus me gusta"\n'
                '• Tus álbumes guardados\n'
                '• Tu historial de escucha y tus estadísticas\n'
                '• Tu perfil y tu avatar',
                style: TextStyle(color: AppTheme.secondary, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 10),
              const Text(
                'No se puede deshacer. Las canciones descargadas en este dispositivo se conservan. '
                'Si quieres guardar tus playlists, expórtalas a CSV antes.',
                style: TextStyle(color: AppTheme.secondary, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              const Text(
                'Escribe $_confirmWord para confirmar:',
                style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(color: AppTheme.primary),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: _confirmWord,
                  hintStyle: const TextStyle(color: AppTheme.muted),
                  filled: true,
                  fillColor: AppTheme.surfaceHover,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            disabledBackgroundColor: AppTheme.surfaceHover,
          ),
          onPressed: canDelete ? () => Navigator.pop(context, true) : null,
          child: const Text('Eliminar cuenta', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
