import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../data/local_db/syncora_database.dart';
import '../services/folder_service.dart';

/// Portada de una carpeta (Fase 8.E): bloque sólido con el ícono, mismo
/// tamaño y radio que las portadas de playlist a su lado.
class FolderCover extends StatelessWidget {
  const FolderCover({super.key, this.size, this.borderRadius = const BorderRadius.all(Radius.circular(10))});

  final double? size;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: AppTheme.surfaceActive, borderRadius: borderRadius),
      child: LayoutBuilder(
        builder: (context, c) {
          final side = c.biggest.shortestSide.isFinite ? c.biggest.shortestSide : 48.0;
          return Center(
            child: Icon(AppIcons.bold(SolarIcons.Folder), color: AppTheme.secondary, size: side * 0.42),
          );
        },
      ),
    );
  }
}

bool _isDesktop(BuildContext context) => MediaQuery.sizeOf(context).width >= 768;

/// Pide un nombre de carpeta. Diálogo centrado en ambas plataformas, igual
/// que "Nueva playlist" (es un campo de texto, no un menú).
Future<String?> showFolderNameDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initialName = '',
}) {
  final controller = TextEditingController(text: initialName);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() {
        final name = FolderService.cleanName(controller.text);
        if (name != null) Navigator.of(ctx).pop(name);
      }

      return AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: FolderService.maxNameLength,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => submit(),
          style: const TextStyle(color: AppTheme.primary),
          decoration: const InputDecoration(
            labelText: 'Nombre de la carpeta',
            labelStyle: TextStyle(color: AppTheme.secondary),
            counterStyle: TextStyle(color: AppTheme.muted),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.surfaceHover)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.primary)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: AppTheme.background),
            onPressed: submit,
            child: Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

/// Crea una carpeta pidiendo el nombre. Devuelve su id local o `null`.
Future<int?> createFolderInteractive(BuildContext context, WidgetRef ref) async {
  final name = await showFolderNameDialog(context, title: 'Nueva carpeta', confirmLabel: 'Crear');
  if (name == null) return null;
  final id = await ref.read(folderServiceProvider).createFolder(name);
  if (context.mounted && id == null) {
    AppToast.show(context, message: 'No se pudo crear la carpeta. Revisa tu conexión.');
  }
  return id;
}

/// Contenedor de menú según plataforma: diálogo centrado en PC, hoja en
/// móvil (directrices de UI del proyecto).
Future<T?> _showMenu<T>(BuildContext context, Widget Function(BuildContext ctx) builder) {
  if (_isDesktop(context)) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF2A2A2A)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380, maxHeight: 520),
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: builder(ctx)),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: builder(ctx)),
      ),
    ),
  );
}

/// "Mover a carpeta" (menú de 3 puntos de una playlist).
Future<void> showMoveToFolderPicker(BuildContext context, WidgetRef ref, Playlist playlist) async {
  // `null` dentro del record = "a la raíz"; el picker devuelve `null` si se
  // cierra sin elegir.
  final choice = await _showMenu<({Folder? folder, bool create})>(
    context,
    (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final folders = ref.watch(foldersProvider).value ?? const <Folder>[];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Mover a carpeta',
                style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            ListTile(
              leading: Icon(AppIcons.broken(SolarIcons.AddFolder), color: AppTheme.primary),
              title: const Text('Nueva carpeta…', style: TextStyle(color: AppTheme.primary)),
              onTap: () => Navigator.pop(ctx, (folder: null, create: true)),
            ),
            if (playlist.folderId != null)
              ListTile(
                leading: Icon(AppIcons.broken(SolarIcons.FolderOpen), color: AppTheme.primary),
                title: const Text('Sacar de la carpeta', style: TextStyle(color: AppTheme.primary)),
                onTap: () => Navigator.pop(ctx, (folder: null, create: false)),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final f in folders)
                    ListTile(
                      leading: SizedBox(width: 36, height: 36, child: const FolderCover()),
                      title: Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppTheme.primary),
                      ),
                      trailing: f.id == playlist.folderId
                          ? Icon(AppIcons.bold(SolarIcons.CheckCircle), color: AppTheme.secondary, size: 20)
                          : null,
                      onTap: f.id == playlist.folderId ? null : () => Navigator.pop(ctx, (folder: f, create: false)),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
  if (choice == null || !context.mounted) return;

  Folder? target = choice.folder;
  if (choice.create) {
    final id = await createFolderInteractive(context, ref);
    if (id == null || !context.mounted) return;
    target = await ref.read(folderServiceProvider).folderById(id);
    if (target == null || !context.mounted) return;
  }

  final ok = await ref.read(folderServiceProvider).movePlaylist(playlist, target);
  if (!context.mounted) return;
  AppToast.show(
    context,
    message: !ok
        ? 'No se pudo mover la playlist. Revisa tu conexión.'
        : (target == null ? 'Playlist sacada de la carpeta' : 'Playlist movida a "${target.name}"'),
  );
}

/// Menú de una carpeta: renombrar y eliminar.
Future<void> showFolderOptions(
  BuildContext context,
  WidgetRef ref,
  Folder folder, {
  required bool canEdit,
  VoidCallback? onDeleted,
}) async {
  final color = canEdit ? AppTheme.primary : AppTheme.muted;
  final action = await _showMenu<String>(
    context,
    (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(AppIcons.broken(SolarIcons.PenNewSquare), color: color),
          title: Text('Renombrar carpeta', style: TextStyle(color: color)),
          enabled: canEdit,
          onTap: () => Navigator.pop(ctx, 'rename'),
        ),
        ListTile(
          leading: Icon(AppIcons.broken(SolarIcons.TrashBinMinimalistic), color: canEdit ? Colors.redAccent : AppTheme.muted),
          title: Text('Eliminar carpeta', style: TextStyle(color: canEdit ? Colors.redAccent : AppTheme.muted)),
          enabled: canEdit,
          onTap: () => Navigator.pop(ctx, 'delete'),
        ),
      ],
    ),
  );
  if (!context.mounted || action == null) return;

  final service = ref.read(folderServiceProvider);
  if (action == 'rename') {
    final name = await showFolderNameDialog(
      context,
      title: 'Renombrar carpeta',
      confirmLabel: 'Guardar',
      initialName: folder.name,
    );
    if (name == null || name == folder.name) return;
    final ok = await service.renameFolder(folder, name);
    if (context.mounted && !ok) {
      AppToast.show(context, message: 'No se pudo renombrar la carpeta. Revisa tu conexión.');
    }
    return;
  }

  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('¿Eliminar "${folder.name}"?', style: const TextStyle(color: AppTheme.primary)),
      content: const Text(
        'Las playlists que contiene no se borran: vuelven a tu biblioteca.',
        style: TextStyle(color: AppTheme.secondary),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Eliminar carpeta'),
        ),
      ],
    ),
  );
  if (confirm != true) return;
  final ok = await service.deleteFolder(folder);
  if (!context.mounted) return;
  if (ok) onDeleted?.call();
  AppToast.show(
    context,
    message: ok ? 'Carpeta eliminada' : 'No se pudo eliminar la carpeta. Revisa tu conexión.',
  );
}
