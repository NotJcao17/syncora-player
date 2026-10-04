import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/images/custom_image_service.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../auth/auth_provider.dart';
import '../../auth/local_mode_provider.dart';
import 'user_avatar.dart';

/// Modal bottom sheet / diálogo centrado para la selección de avatar basado en Dicebear seeds.
class AvatarSelectorSheet extends ConsumerStatefulWidget {
  final String? currentSeed;
  // Fase 7.I.4: `Future<void> Function` (no `ValueChanged`, que es
  // síncrono) para poder `await`ar el guardado local sin que quede como un
  // "fire and forget" cuyo error, si lo hay, se pierde como excepción de
  // Future sin capturar (hallazgo de la revisión independiente).
  final Future<void> Function(String seed)? onAvatarSelected;
  final bool isDialog;

  const AvatarSelectorSheet({
    super.key,
    this.currentSeed,
    this.onAvatarSelected,
    this.isDialog = false,
  });

  static const List<String> avatarSeeds = [
    'USER_UUID_PLACEHOLDER',
    'cosmic-wolf',
    'neon-fox',
    'lunar-cat',
    'pixel-dragon',
    'velvet-crow',
    'solar-rabbit',
    'echo-bear',
    'nova-panda',
    'cipher-owl',
    'drift-lynx',
    'flux-tiger',
    'orbit-deer',
    'prism-hawk',
    'quasar-seal',
    'rune-moose',
    'spark-otter',
    'tidal-crane',
    'ultra-mink',
    'vortex-bat',
    'wave-bison',
    'xenon-raven',
    'yield-ferret',
    'zenith-stoat',
  ];

  static Future<void> show(
    BuildContext context, {
    String? currentSeed,
    Future<void> Function(String seed)? onAvatarSelected,
  }) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isDesktop = (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) || screenWidth >= 768;

    if (isDesktop) {
      return showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 540),
            child: AvatarSelectorSheet(
              currentSeed: currentSeed,
              onAvatarSelected: onAvatarSelected,
              isDialog: true,
            ),
          ),
        ),
      );
    }

    return showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AvatarSelectorSheet(
        currentSeed: currentSeed,
        onAvatarSelected: onAvatarSelected,
        isDialog: false,
      ),
    );
  }

  @override
  ConsumerState<AvatarSelectorSheet> createState() =>
      _AvatarSelectorSheetState();
}

class _AvatarSelectorSheetState extends ConsumerState<AvatarSelectorSheet> {
  late String _selectedSeed;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState() ;
    _selectedSeed = widget.currentSeed ?? '';
  }

  bool _isTestEnvironment() {
    return Platform.environment.containsKey('FLUTTER_TEST');
  }

  Future<void> _handleSelectSeed(String seed, String userId) async {
    // Con cuenta, el avatar vive en `profiles` (Supabase). Sin conexión la
    // selección no se puede persistir, así que no se aplica a medias. En modo
    // local `userId` viene vacío y `canEdit` es `true`, así que el camino
    // 100% local sigue funcionando igual.
    if (userId.isNotEmpty && !ref.read(canEditProvider)) {
      AppToast.show(context, message: 'Sin conexión. No se puede cambiar el avatar offline.');
      return;
    }
    setState(() {
      _selectedSeed = seed;
      _isSaving = true;
    });

    // Elegir una semilla quita la foto propia: si no, la elección no se vería.
    final hadPhoto = ref.read(avatarInfoProvider).hasImage;
    try {
      if (!_isTestEnvironment() && userId.isNotEmpty) {
        await Supabase.instance.client
            .from('profiles')
            // `avatar_url` solo si hace falta: sin la migración 19 aplicada,
            // mandarlo rompería también el cambio de semilla.
            .update({'avatar_seed': seed, if (hadPhoto) 'avatar_url': null}).eq('id', userId);
        ref.invalidate(profileProvider);
        if (hadPhoto) unawaited(ref.read(customImageServiceProvider).collectGarbage());
      } else if (userId.isEmpty && hadPhoto) {
        await _setLocalPhoto(null);
      }
      await widget.onAvatarSelected?.call(seed);
    } catch (e) {
      if (mounted) {
        AppToast.show(
          context,
          message: 'Error al actualizar avatar: ${ErrorStateWidget.formatErrorMessage(e)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  /// Modo local: guarda (o quita, con `null`) la ruta de la foto y borra el
  /// archivo anterior.
  Future<void> _setLocalPhoto(String? path) async {
    final storage = ref.read(localModeStorageProvider);
    final previous = await storage.getAvatarImagePath();
    await storage.setAvatarImagePath(path);
    if (previous != null && previous != path) {
      await ref.read(customImageServiceProvider).deleteLocal(previous);
    }
    ref.invalidate(localAvatarImageProvider);
  }

  Future<void> _uploadPhoto(String userId) async {
    if (_isSaving) return;
    if (userId.isNotEmpty && !ref.read(canEditProvider)) {
      AppToast.show(context, message: 'Necesitas conexión a internet para cambiar tu foto.');
      return;
    }
    final service = ref.read(customImageServiceProvider);
    setState(() => _isSaving = true);
    try {
      final raw = await service.pickImage();
      if (raw == null) return;
      final jpeg = await service.prepare(raw, CustomImageKind.avatar);
      if (userId.isEmpty) {
        await _setLocalPhoto(await service.saveLocal(jpeg));
      } else {
        final url = await service.upload(jpeg, CustomImageKind.avatar);
        await Supabase.instance.client.from('profiles').update({'avatar_url': url}).eq('id', userId);
        // La foto anterior la recoge la siguiente subida o limpieza: pedirlo
        // aquí gastaría otra operación del cupo diario.
        ref.invalidate(profileProvider);
      }
      if (mounted) AppToast.show(context, message: 'Foto de perfil actualizada');
    } on CustomImageException catch (e) {
      if (mounted) AppToast.show(context, message: e.message);
    } catch (e) {
      if (mounted) {
        AppToast.show(context, message: 'No se pudo cambiar la foto: ${ErrorStateWidget.formatErrorMessage(e)}');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _removePhoto(String userId) async {
    if (_isSaving) return;
    if (userId.isNotEmpty && !ref.read(canEditProvider)) {
      AppToast.show(context, message: 'Necesitas conexión a internet para quitar tu foto.');
      return;
    }
    setState(() => _isSaving = true);
    try {
      if (userId.isEmpty) {
        await _setLocalPhoto(null);
      } else {
        await Supabase.instance.client.from('profiles').update({'avatar_url': null}).eq('id', userId);
        ref.invalidate(profileProvider);
        unawaited(ref.read(customImageServiceProvider).collectGarbage());
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, message: 'No se pudo quitar la foto: ${ErrorStateWidget.formatErrorMessage(e)}');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildPhotoRow(String userId, bool hasPhoto) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          if (hasPhoto) ...[
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.surfaceActive, width: 3),
                boxShadow: AppTheme.glowShadow,
              ),
              child: const UserAvatar(size: 44),
            ),
            const SizedBox(width: 12),
          ],
          OutlinedButton.icon(
            onPressed: _isSaving ? null : () => _uploadPhoto(userId),
            icon: Icon(AppIcons.broken(SolarIcons.GalleryAdd), size: 18, color: AppTheme.primary),
            label: Text(
              hasPhoto ? 'Cambiar foto' : 'Subir foto',
              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.surfaceHover),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
          ),
          if (hasPhoto) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: _isSaving ? null : () => _removePhoto(userId),
              child: const Text('Quitar', style: TextStyle(color: AppTheme.secondary)),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPhoto = ref.watch(avatarInfoProvider).hasImage;
    final user = ref.watch(currentUserProvider);
    String userId = user?.id ?? '';
    if (userId.isEmpty && !_isTestEnvironment()) {
      try {
        userId = Supabase.instance.client.auth.currentUser?.id ?? '';
      } catch (_) {}
    }
    // Fase 7.I.4: en modo local no hay `userId` -- el slot "tu avatar único"
    // usa la semilla local ya generada (`currentSeed`, pasada por
    // `settings_screen.dart`) en vez de caer siempre en el mismo
    // `'default'` genérico para todo el mundo sin cuenta.
    final placeholderSeed = userId.isNotEmpty
        ? userId
        : (widget.currentSeed != null && widget.currentSeed!.isNotEmpty ? widget.currentSeed! : 'default');

    final effectiveSeeds = AvatarSelectorSheet.avatarSeeds.map((seed) {
      return seed == 'USER_UUID_PLACEHOLDER' ? placeholderSeed : seed;
    }).toList();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: widget.isDialog
            ? BorderRadius.circular(20)
            : const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: widget.isDialog ? null : AppTheme.surfaceUpShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.isDialog) ...[
            // Indicator handle
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.surfaceActive,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
          ] else ...[
            const SizedBox(height: 20),
          ],

          // Sheet Title / Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Elige tu Avatar',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary,
                    letterSpacing: -0.5,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isSaving)
                      const Padding(
                        padding: EdgeInsets.only(right: 8.0),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.primary,
                          ),
                        ),
                      ),
                    if (widget.isDialog)
                      IconButton(
                        icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary, size: 22),
                        onPressed: () => Navigator.of(context).pop(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildPhotoRow(userId, hasPhoto),
          const SizedBox(height: 8),

          // Grid de 24 semillas de avatares
          Flexible(
            child: GridView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 1.0,
              ),
              itemCount: effectiveSeeds.length,
              itemBuilder: (context, index) {
                final seed = effectiveSeeds[index];
                final isSelected = !hasPhoto && seed == _selectedSeed;
                final avatarUrl =
                    'https://api.dicebear.com/9.x/adventurer-neutral/svg?seed=$seed';

                return InkWell(
                  onTap: () => _handleSelectSeed(seed, userId),
                  borderRadius: BorderRadius.circular(16),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      color: AppTheme.background,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF2C3647)
                            : Colors.transparent,
                        width: isSelected ? 3.5 : 0,
                      ),
                      boxShadow: isSelected ? AppTheme.glowShadow : null,
                    ),
                    padding: const EdgeInsets.all(6),
                    child: ClipOval(
                      child: _isTestEnvironment()
                          ? Container(
                              color: AppTheme.surfaceHover,
                              child: const Icon(
                                Icons.face,
                                color: AppTheme.secondary,
                                size: 28,
                              ),
                            )
                          : SvgPicture.network(
                              avatarUrl,
                              fit: BoxFit.cover,
                              placeholderBuilder: (context) => Container(
                                color: AppTheme.surfaceHover,
                                child: const Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      color: AppTheme.secondary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
