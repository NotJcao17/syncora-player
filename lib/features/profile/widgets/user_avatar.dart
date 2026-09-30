import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/cache/app_image_cache.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/local_image_path.dart';
import '../../auth/auth_provider.dart';
import '../../auth/local_mode_provider.dart';

/// Avatar del usuario: foto propia si la tiene, si no la semilla de DiceBear.
class AvatarInfo {
  final String seed;

  /// URL pública (con cuenta) o ruta local (modo local) de la foto propia.
  final String? imageUrl;

  const AvatarInfo({required this.seed, this.imageUrl});

  bool get hasImage => imageUrl != null && imageUrl!.isNotEmpty;

  static String diceBearUrl(String seed) => 'https://api.dicebear.com/9.x/adventurer-neutral/svg?seed=$seed';
}

/// Única fuente del avatar para toda la app. Con cuenta sale de `profiles`
/// (`avatar_url`, `avatar_seed`); en modo local, de `LocalModeStorage`.
final avatarInfoProvider = Provider<AvatarInfo>((ref) {
  if (ref.watch(localModeProvider)) {
    return AvatarInfo(
      seed: ref.watch(localAvatarSeedProvider).value ?? 'default-seed',
      imageUrl: ref.watch(localAvatarImageProvider).value,
    );
  }
  final profile = ref.watch(profileProvider).value;
  final user = ref.watch(currentUserProvider);
  return AvatarInfo(
    seed: profile?['avatar_seed'] as String? ?? user?.id ?? 'default-seed',
    imageUrl: profile?['avatar_url'] as String?,
  );
});

/// Avatar circular de [size] px. Antes se copiaba el mismo `SvgPicture` en
/// cuatro pantallas; con la foto propia eso serían cuatro sitios que olvidar.
class UserAvatar extends ConsumerWidget {
  final double size;

  const UserAvatar({super.key, required this.size});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(avatarInfoProvider);
    final cachePx = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final diceBear = SvgPicture.network(
      AvatarInfo.diceBearUrl(info.seed),
      width: size,
      height: size,
      fit: BoxFit.cover,
      placeholderBuilder: (_) => _placeholder(),
    );

    Widget child = diceBear;
    if (info.hasImage) {
      final image = info.imageUrl!;
      child = isLocalImagePath(image)
          ? Image.file(
              File(localImageFilePath(image)),
              fit: BoxFit.cover,
              cacheWidth: cachePx,
              errorBuilder: (_, _, _) => diceBear,
            )
          : CachedNetworkImage(
              cacheManager: AppImageCache.instance,
              imageUrl: image,
              fit: BoxFit.cover,
              memCacheWidth: cachePx,
              placeholder: (_, _) => _placeholder(),
              errorWidget: (_, _, _) => diceBear,
            );
    }

    return ClipOval(
      child: Container(width: size, height: size, color: AppTheme.surfaceActive, child: child),
    );
  }

  Widget _placeholder() => Container(
        color: AppTheme.surfaceHover,
        child: Icon(AppIcons.broken(SolarIcons.User), color: AppTheme.muted, size: size * 0.5),
      );
}
