import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../widgets/app_bottom_sheet.dart';
import 'app_update.dart';
import 'app_update_service.dart';

/// Aviso de versión nueva: hoja en el teléfono, diálogo en la PC.
///
/// [fromStartup] agrega "Omitir esta versión" (desde Configuración no tiene
/// sentido: el usuario la buscó a propósito).
Future<void> showAppUpdateSheet(
  BuildContext context,
  AvailableUpdate update, {
  bool fromStartup = false,
}) {
  return AppBottomSheet.show<void>(
    context: context,
    title: 'Nueva versión disponible',
    child: AppUpdateSheet(update: update, fromStartup: fromStartup),
  );
}

enum _Phase { idle, downloading, installing, waitingInstaller, error }

class AppUpdateSheet extends ConsumerStatefulWidget {
  const AppUpdateSheet({super.key, required this.update, this.fromStartup = false});

  final AvailableUpdate update;
  final bool fromStartup;

  @override
  ConsumerState<AppUpdateSheet> createState() => _AppUpdateSheetState();
}

class _AppUpdateSheetState extends ConsumerState<AppUpdateSheet> {
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  String _error = '';
  UpdateCancelToken? _cancel;

  @override
  void dispose() {
    // Cerrar la hoja a mitad de la descarga la cancela.
    _cancel?.cancel();
    super.dispose();
  }

  bool get _isAndroid => ref.read(appUpdateServiceProvider).platform == UpdatePlatform.android;

  Future<void> _start() async {
    final service = ref.read(appUpdateServiceProvider);
    final cancel = UpdateCancelToken();
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _cancel = cancel;
    });
    try {
      final file = await service.download(
        widget.update,
        cancel: cancel,
        onProgress: (received, total) {
          if (!mounted) return;
          final value = total <= 0 ? 0.0 : received / total;
          // Repintar solo cada ~1 %: llegan cientos de trozos por segundo.
          if ((value - _progress).abs() >= 0.01 || value >= 1) setState(() => _progress = value);
        },
      );
      if (!mounted || cancel.isCancelled) return;
      await _install(file);
    } on UpdateCancelled {
      return;
    } on UpdateCorrupted {
      _fail('El archivo descargado no coincide con el publicado. Vuelve a intentarlo.');
    } catch (_) {
      _fail('No se pudo descargar la actualización. Revisa tu conexión y vuelve a intentarlo.');
    }
  }

  Future<void> _install(File file) async {
    setState(() => _phase = _Phase.installing);
    final ok = await ref.read(appUpdateServiceProvider).install(file);
    if (!mounted) return;
    if (!ok) {
      _fail('No se pudo abrir el instalador.');
      return;
    }
    // En Windows la app ya se está cerrando. En Android el instalador del
    // sistema queda encima: si el usuario lo cancela o tiene que ir a dar el
    // permiso, al volver puede reintentar (el archivo ya está bajado).
    if (_isAndroid) setState(() => _phase = _Phase.waitingInstaller);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _error = message;
    });
  }

  Future<void> _skip() async {
    await ref.read(appUpdateServiceProvider).skip(widget.update.version);
    if (mounted) AppBottomSheet.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width >= 720;
    final update = widget.update;
    return SingleChildScrollView(
      padding: isDesktop ? EdgeInsets.zero : const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: AppTheme.surfaceHover, borderRadius: BorderRadius.circular(12)),
                child: Icon(AppIcons.broken(SolarIcons.Download), color: AppTheme.primary, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Syncora Player ${update.version}',
                      style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatUpdateSize(update.size),
                      style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (update.notes.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Text(update.notes, style: const TextStyle(color: AppTheme.primary, fontSize: 14, height: 1.4)),
              ),
            )
          else
            const Text(
              'Trae correcciones y mejoras.',
              style: TextStyle(color: AppTheme.primary, fontSize: 14),
            ),
          if (update.pageUrl.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.secondary,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 36),
                ),
                onPressed: () => launchUrl(Uri.parse(update.pageUrl), mode: LaunchMode.externalApplication),
                child: const Text('Ver todos los cambios'),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            _isAndroid
                ? 'Android te pedirá confirmar la instalación. Tu biblioteca y tus descargas se conservan.'
                : 'Syncora se cerrará unos segundos y se abrirá ya actualizada. Tu biblioteca y tus descargas se conservan.',
            style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 20),
          ..._actions(),
        ],
      ),
    );
  }

  List<Widget> _actions() {
    switch (_phase) {
      case _Phase.idle:
        return [
          _primaryButton('Actualizar', _start),
          const SizedBox(height: 4),
          _secondaryButton('Ahora no', () => AppBottomSheet.pop(context)),
          if (widget.fromStartup) _secondaryButton('Omitir esta versión', _skip),
        ];
      case _Phase.downloading:
        final mb = (widget.update.size * _progress) / (1024 * 1024);
        return [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 6,
              backgroundColor: AppTheme.surfaceHover,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Descargando… ${mb.toStringAsFixed(1)} de ${formatUpdateSize(widget.update.size)}',
            style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _secondaryButton('Cancelar', () {
            _cancel?.cancel();
            setState(() => _phase = _Phase.idle);
          }),
        ];
      case _Phase.installing:
        return [
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: AppTheme.primary),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _isAndroid ? 'Abriendo el instalador…' : 'Instalando… Syncora se cerrará en un momento.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
          ),
        ];
      case _Phase.waitingInstaller:
        return [
          const Text(
            'Sigue los pasos del instalador. Si Android te pide permitir instalar apps de Syncora, '
            'actívalo y vuelve. Si cerraste el instalador, toca "Instalar" para abrirlo otra vez.',
            style: TextStyle(color: AppTheme.secondary, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          _primaryButton('Instalar', _start),
          const SizedBox(height: 4),
          _secondaryButton('Cerrar', () => AppBottomSheet.pop(context)),
        ];
      case _Phase.error:
        return [
          Text(_error, style: const TextStyle(color: AppTheme.secondary, fontSize: 13, height: 1.4)),
          const SizedBox(height: 16),
          _primaryButton('Reintentar', _start),
          const SizedBox(height: 4),
          _secondaryButton('Cerrar', () => AppBottomSheet.pop(context)),
        ];
    }
  }

  Widget _primaryButton(String label, VoidCallback onPressed) => SizedBox(
        height: 46,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: AppTheme.background,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
          ),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      );

  Widget _secondaryButton(String label, VoidCallback onPressed) => SizedBox(
        height: 44,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(foregroundColor: AppTheme.secondary),
          child: Text(label),
        ),
      );
}
