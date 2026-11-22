import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:syncora_android/syncora_android.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import 'app_toast.dart';

/// ¿El launcher deja poner widgets desde la app? Se pregunta una sola vez.
final Future<bool> _pinSupported =
    (!kIsWeb && Platform.isAndroid) ? SyncoraAndroid.isPinSupported() : Future.value(false);

/// Opción de menú "Agregar a la pantalla de inicio" (ronda 13): pone un widget
/// que abre [collection]. No aparece en Windows ni si el launcher no lo
/// permite (ahí se agrega desde la lista de widgets del launcher).
class AddToHomeScreenTile extends StatelessWidget {
  const AddToHomeScreenTile({super.key, required this.menuContext, required this.collection});

  /// Contexto del menú, para cerrarlo.
  final BuildContext menuContext;
  final WidgetCollection collection;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _pinSupported,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        return ListTile(
          leading: Icon(AppIcons.broken(SolarIcons.Widget), color: AppTheme.primary),
          title: const Text(
            'Agregar a la pantalla de inicio',
            style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600),
          ),
          onTap: () async {
            final messenger = Navigator.of(menuContext).context;
            Navigator.pop(menuContext);
            final ok = await SyncoraAndroid.pinCollection(collection);
            if (!ok && messenger.mounted) {
              AppToast.show(
                messenger,
                message: 'Tu pantalla de inicio no deja agregarlo desde aquí. Mantén pulsado un espacio vacío → Widgets → Syncora.',
              );
            }
          },
        );
      },
    );
  }
}
