import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/horizontal_scroller.dart';
import '../../../core/cache/app_image_cache.dart';

/// Acción opcional a la derecha del título de una sección ("Ver todos").
class HomeSectionAction {
  final String label;
  final VoidCallback onPressed;

  const HomeSectionAction({required this.label, required this.onPressed});
}

/// Bloque estándar de Inicio: título, subtítulo opcional, acción opcional y
/// contenido.
///
/// Devuelve un sliver porque Inicio es un `CustomScrollView`: así cada sección
/// se compone sin anidar scrolls, y el contenido horizontal de cada una sigue
/// siendo su propio `ListView`.
class HomeSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool isDesktop;
  final double padding;
  final HomeSectionAction? action;
  final Widget child;

  const HomeSection({
    super.key,
    required this.title,
    required this.isDesktop,
    required this.padding,
    required this.child,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(padding, 28, padding, subtitle == null ? 14 : 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: AppTheme.primary,
                          fontSize: isDesktop ? 22 : 19,
                        ),
                  ),
                ),
                if (action != null)
                  TextButton(
                    onPressed: action!.onPressed,
                    child: Text(
                      action!.label,
                      style: const TextStyle(color: AppTheme.accent, fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 0, padding, 14),
              child: Text(
                subtitle!,
                style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

/// Fila horizontal de tarjetas con el ancho y alto estándar de Inicio.
class HomeCardRow extends StatelessWidget {
  final bool isDesktop;
  final double padding;
  final int itemCount;
  final Widget Function(int index) itemBuilder;

  const HomeCardRow({
    super.key,
    required this.isDesktop,
    required this.padding,
    required this.itemCount,
    required this.itemBuilder,
  });

  /// Tamaño de tarjeta.
  ///
  /// En móvil subió de 140x200 a 168x232: con 140 px de ancho el título se
  /// cortaba casi siempre y la portada quedaba pequeña de más. En escritorio se
  /// deja igual, que ahí se veía bien.
  static double cardWidth(bool isDesktop) => isDesktop ? 180 : 168;

  static double rowHeight(bool isDesktop) => isDesktop ? 240 : 232;

  @override
  Widget build(BuildContext context) {
    return HorizontalScroller(
      height: rowHeight(isDesktop),
      padding: EdgeInsets.symmetric(horizontal: padding),
      itemCount: itemCount,
      itemBuilder: (ctx, i) => SizedBox(width: cardWidth(isDesktop), child: itemBuilder(i)),
    );
  }
}

/// Artista como círculo con su nombre debajo.
class HomeArtistCircle extends StatelessWidget {
  final String name;
  final String pictureUrl;
  final double size;
  final VoidCallback onTap;

  const HomeArtistCircle({
    super.key,
    required this.name,
    required this.pictureUrl,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size),
      child: SizedBox(
        width: size,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipOval(
              child: SizedBox(
                width: size,
                height: size,
                child: pictureUrl.isEmpty
                    ? Container(color: AppTheme.surfaceHover)
                    : CachedNetworkImage(cacheManager: AppImageCache.instance, imageUrl: pictureUrl, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// Género como tarjeta ancha con la imagen oficial de Deezer de fondo.
///
/// El velo oscuro no es decorativo: esas imágenes son collages claros y el
/// nombre encima quedaba ilegible sin él.
class HomeGenreTile extends StatelessWidget {
  final String name;
  final String imageUrl;
  final VoidCallback onTap;

  const HomeGenreTile({
    super.key,
    required this.name,
    required this.imageUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: AppTheme.surfaceHover),
            if (imageUrl.isNotEmpty)
              CachedNetworkImage(
                cacheManager: AppImageCache.instance,
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            Container(color: Colors.black.withValues(alpha: 0.42)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
