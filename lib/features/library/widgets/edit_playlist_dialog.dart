import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/images/custom_image_service.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/playlist_cover_widget.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../auth/local_mode_provider.dart';
import '../services/playlist_cover_service.dart';
import '../../../core/limits/app_limits.dart';

Future<void> showEditPlaylistDialog(BuildContext context, Playlist playlist) {
  return showDialog<void>(
    context: context,
    builder: (_) => EditPlaylistDialog(playlist: playlist),
  );
}

/// Editar nombre, descripción y portada de una playlist propia.
///
/// La imagen propia se elige y se procesa al momento (para verla), pero no
/// se guarda ni se sube hasta "Guardar cambios": cancelar no deja nada en el
/// dispositivo ni en la nube.
class EditPlaylistDialog extends ConsumerStatefulWidget {
  final Playlist playlist;

  const EditPlaylistDialog({super.key, required this.playlist});

  @override
  ConsumerState<EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends ConsumerState<EditPlaylistDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _descController;
  String? _selectedCover;
  Uint8List? _pendingImage;
  bool _isProcessing = false;
  bool _isSaving = false;

  Playlist get _playlist => widget.playlist;

  /// Con cuenta la imagen va a la nube; sin cuenta, o si la playlist todavía
  /// no existe en la nube, se queda en el dispositivo.
  bool get _isCloud => _playlist.remoteId != null && !ref.read(localModeProvider);

  bool get _hasImageSelected => _pendingImage != null || isImageCover(_selectedCover);

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: _playlist.title);
    _descController = TextEditingController(text: _playlist.description ?? '');
    _selectedCover = _playlist.coverUrl;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _selectPreset(String? cover) {
    setState(() {
      _pendingImage = null;
      _selectedCover = cover;
    });
  }

  Future<void> _pickImage() async {
    if (_isProcessing || _isSaving) return;
    final service = ref.read(customImageServiceProvider);
    setState(() => _isProcessing = true);
    try {
      final raw = await service.pickImage();
      if (raw == null) return;
      final jpeg = await service.prepare(raw, CustomImageKind.playlistCover);
      if (mounted) setState(() => _pendingImage = jpeg);
    } on CustomImageException catch (e) {
      if (mounted) AppToast.show(context, message: e.message);
    } catch (_) {
      if (mounted) AppToast.show(context, message: 'No se pudo abrir la imagen.');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _save() async {
    final newTitle = _titleController.text.trim();
    if (newTitle.isEmpty || _isSaving || _isProcessing) return;
    final newDesc = _descController.text.trim();
    final service = ref.read(customImageServiceProvider);
    final isCloud = _isCloud;

    setState(() => _isSaving = true);

    String? newCover = _selectedCover;
    final pending = _pendingImage;
    if (pending != null) {
      try {
        if (isCloud) {
          if (!ref.read(canEditProvider)) {
            throw const CustomImageException('Necesitas conexión a internet para cambiar la portada.');
          }
          newCover = await service.upload(pending, CustomImageKind.playlistCover, playlistRemoteId: _playlist.remoteId);
        } else {
          newCover = await service.saveLocal(pending);
        }
      } on CustomImageException catch (e) {
        if (mounted) {
          setState(() => _isSaving = false);
          AppToast.show(context, message: e.message);
        }
        return;
      } catch (_) {
        if (mounted) {
          setState(() => _isSaving = false);
          AppToast.show(context, message: 'No se pudo guardar la imagen.');
        }
        return;
      }
    }

    final dao = ref.read(playlistDaoProvider);
    await dao.updatePlaylist(_playlist.copyWith(
      title: newTitle,
      description: Value(newDesc.isEmpty ? null : newDesc),
      coverUrl: Value(newCover),
    ));

    if (_playlist.remoteId != null) {
      try {
        await ref.read(supabasePlaylistRepositoryProvider).updatePlaylist(
              _playlist.remoteId!,
              title: newTitle,
              description: newDesc.isEmpty ? null : newDesc,
              clearDescription: newDesc.isEmpty,
              coverUrl: newCover,
              // Volver a portada automática es un NULL explícito, no un "no
              // lo toques".
              clearCoverUrl: newCover == null,
            );
      } catch (_) {}
    }

    if (newCover != _playlist.coverUrl) releaseCoverImage(ref, _playlist, replacedBy: newCover);

    if (!mounted) return;
    Navigator.pop(context);
    AppToast.show(context, message: 'Playlist actualizada');
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isSaving || _isProcessing;
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Editar playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          // La etiqueta flotante del primer campo sube por encima de su borde:
          // sin este margen el scroll la recortaba ("Nombre de la playlist").
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _textField(_titleController, 'Nombre de la playlist', maxLength: AppLimits.playlistTitleMax),
              const SizedBox(height: 12),
              _textField(
                _descController,
                'Descripción (opcional)',
                maxLines: 2,
                maxLength: AppLimits.playlistDescriptionMax,
              ),
              const SizedBox(height: 16),
              const Text('Personalizar portada',
                  style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),
              _buildImageOption(),
              const Divider(color: AppTheme.surfaceHover, height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _optionIcon(AppIcons.broken(SolarIcons.Widget)),
                title: const Text('Cuadrícula 2x2 automática',
                    style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600)),
                trailing: (_pendingImage == null && (_selectedCover == null || _selectedCover!.isEmpty))
                    ? Icon(AppIcons.bold(SolarIcons.CheckCircle), color: AppTheme.primary, size: 20)
                    : null,
                onTap: busy ? null : () => _selectPreset(null),
              ),
              const Divider(color: AppTheme.surfaceHover, height: 16),
              const Text('Degradados predefinidos', style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(PlaylistCoverWidget.presetGradients.length, (idx) {
                  final tag = 'gradient:$idx';
                  return _swatch(
                    tag: tag,
                    decoration: BoxDecoration(gradient: PlaylistCoverWidget.presetGradients[idx]),
                  );
                }),
              ),
              const SizedBox(height: 12),
              const Text('Colores sólidos', style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(PlaylistCoverWidget.presetColors.length, (idx) {
                  final color = PlaylistCoverWidget.presetColors[idx];
                  final hex = '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
                  return _swatch(tag: 'color:$hex', decoration: BoxDecoration(color: color));
                }),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: AppTheme.background,
          ),
          onPressed: busy ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.background))
              : const Text('Guardar cambios', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  /// Vista previa de la imagen propia y botón para elegirla.
  Widget _buildImageOption() {
    final Widget preview;
    if (_pendingImage != null) {
      preview = Image.memory(_pendingImage!, fit: BoxFit.cover);
    } else if (isImageCover(_selectedCover)) {
      preview = PlaylistCoverWidget(coverUrl: _selectedCover, borderRadius: BorderRadius.zero);
    } else {
      preview = Container(
        color: AppTheme.surfaceHover,
        child: Icon(AppIcons.broken(SolarIcons.GalleryAdd), color: AppTheme.primary, size: 22),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: (_isProcessing || _isSaving) ? null : _pickImage,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(width: 56, height: 56, child: preview),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _hasImageSelected ? 'Cambiar imagen' : 'Subir imagen',
                  style: const TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (_isProcessing)
                const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary))
              else if (_hasImageSelected)
                Icon(AppIcons.bold(SolarIcons.CheckCircle), color: AppTheme.primary, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _optionIcon(IconData icon) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: AppTheme.surfaceHover, borderRadius: BorderRadius.circular(8)),
      child: Icon(icon, color: AppTheme.primary, size: 20),
    );
  }

  Widget _swatch({required String tag, required BoxDecoration decoration}) {
    final isSelected = _pendingImage == null && _selectedCover == tag;
    return GestureDetector(
      onTap: (_isProcessing || _isSaving) ? null : () => _selectPreset(tag),
      child: Container(
        width: 40,
        height: 40,
        decoration: decoration.copyWith(
          borderRadius: BorderRadius.circular(8),
          border: isSelected ? Border.all(color: Colors.white, width: 2.5) : null,
        ),
        child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
      ),
    );
  }

  Widget _textField(TextEditingController controller, String label, {int maxLines = 1, int? maxLength}) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      maxLength: maxLength,
      buildCounter: AppLimits.quietCounter,
      style: const TextStyle(color: AppTheme.primary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppTheme.secondary),
        filled: true,
        fillColor: AppTheme.background,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }
}
