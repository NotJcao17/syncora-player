import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../features/player/widgets/mini_player.dart';
import '../theme/app_theme.dart';

/// Layout adaptativo de la aplicación (Móvil vs Desktop calcado de los mockups HTML).
class AppShell extends StatelessWidget {
  final Widget child;
  final String location;

  const AppShell({
    super.key,
    required this.child,
    required this.location,
  });

  int _calculateSelectedIndex() {
    if (location.startsWith('/search')) return 1;
    if (location.startsWith('/library')) return 2;
    return 0; // Default: Home '/'
  }

  void _onItemTapped(int index, BuildContext context) {
    switch (index) {
      case 0:
        context.go('/');
        break;
      case 1:
        context.go('/search');
        break;
      case 2:
        context.go('/library');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final selectedIndex = _calculateSelectedIndex();

    if (isDesktop) {
      return _buildDesktopLayout(context, selectedIndex);
    } else {
      return _buildMobileLayout(context, selectedIndex);
    }
  }

  /// Layout Móvil (Android / pantallas < 768px)
  /// Replica el patrón del mockup: MiniPlayer (tarjeta blanca con -mb-6) solapando
  /// una nav bar custom de fondo surface con bordes redondeados superiores.
  Widget _buildMobileLayout(BuildContext context, int selectedIndex) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: child,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mini-player flotante (se encarga de su propia forma y sombra).
            // Con transform negativo solapa la nav bar, replicando "-mb-6" del mockup.
            Transform.translate(
              offset: const Offset(0, 24),
              child: const MiniPlayer(),
            ),
            _MobileNavBar(
              selectedIndex: selectedIndex,
              onItemTapped: (idx) => _onItemTapped(idx, context),
            ),
          ],
        ),
      ),
    );
  }

  /// Layout Desktop (Windows / pantallas >= 768px calcado de index.html mockup)
  Widget _buildDesktopLayout(BuildContext context, int selectedIndex) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Column(
        children: [
          // Área principal: Sidebar izquierdo + Contenido central
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Sidebar Izquierdo (w-64 = 256px, calcado de index.html)
                Container(
                  width: 256,
                  decoration: const BoxDecoration(
                    color: AppTheme.background,
                    border: Border(
                      right: BorderSide(color: AppTheme.surface, width: 1),
                    ),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Logo oficial de Syncora (fallback al círculo blanco+music del mockup)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.asset(
                                'assets/icon/icon.png',
                                width: 32,
                                height: 32,
                                errorBuilder: (_, _, _) => Container(
                                  width: 32,
                                  height: 32,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppTheme.primary,
                                  ),
                                  child: const Icon(LucideIcons.music, color: AppTheme.background, size: 16),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Text(
                              'Syncora',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primary,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Nav Items Principales (Home, Browse, Library)
                      _DesktopSidebarItem(
                        icon: LucideIcons.house,
                        label: 'Inicio',
                        isSelected: selectedIndex == 0,
                        onTap: () => _onItemTapped(0, context),
                      ),
                      _DesktopSidebarItem(
                        icon: LucideIcons.search,
                        label: 'Buscar',
                        isSelected: selectedIndex == 1,
                        onTap: () => _onItemTapped(1, context),
                      ),
                      _DesktopSidebarItem(
                        icon: LucideIcons.library,
                        label: 'Biblioteca',
                        isSelected: selectedIndex == 2,
                        onTap: () => _onItemTapped(2, context),
                      ),

                      const SizedBox(height: 24),

                      // Sección de Playlists (mockup index.html línea 39)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'PLAYLISTS',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.secondary,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      Expanded(
                        child: ListView(
                          children: [
                            _DesktopPlaylistItem(
                              title: 'Synthwave Mix',
                              isSelected: location.endsWith('p1'),
                              onTap: () => context.push('/playlist/p1'),
                            ),
                            _DesktopPlaylistItem(
                              title: 'Late Night Drive',
                              isSelected: location.endsWith('p2'),
                              onTap: () => context.push('/playlist/p2'),
                            ),
                            _DesktopPlaylistItem(
                              title: 'Focus 2024',
                              isSelected: location.endsWith('p3'),
                              onTap: () => context.push('/playlist/p3'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Área de Contenido Central
                Expanded(
                  child: child,
                ),
              ],
            ),
          ),

          // MiniPlayer continuo de ancho completo en la parte inferior
          const MiniPlayer(),
        ],
      ),
    );
  }
}

/// Nav bar móvil custom calcada del mockup (nav con rounded-t-xl y shadow direccional).
class _MobileNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemTapped;

  const _MobileNavBar({required this.selectedIndex, required this.onItemTapped});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        boxShadow: AppTheme.bottomNavShadow,
      ),
      padding: const EdgeInsets.only(top: 12, bottom: 16, left: 48, right: 48),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _NavDestination(
            icon: LucideIcons.house,
            label: 'Inicio',
            isSelected: selectedIndex == 0,
            onTap: () => onItemTapped(0),
          ),
          _NavDestination(
            icon: LucideIcons.search,
            label: 'Buscar',
            isSelected: selectedIndex == 1,
            onTap: () => onItemTapped(1),
          ),
          _NavDestination(
            icon: LucideIcons.library,
            label: 'Biblioteca',
            isSelected: selectedIndex == 2,
            onTap: () => onItemTapped(2),
          ),
        ],
      ),
    );
  }
}

/// Destino individual de la nav bar móvil (icono + label).
class _NavDestination extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavDestination({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppTheme.primary : AppTheme.muted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: color,
              size: 24,
              fill: isSelected ? 1.0 : 0.0,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Item del sidebar desktop (calcado: px-3 py-2 rounded-lg gap-4, activo bg-surface-hover).
class _DesktopSidebarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _DesktopSidebarItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppTheme.primary : AppTheme.muted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 300),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected ? AppTheme.surfaceHover : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(icon, color: color, size: 20, fill: isSelected ? 1.0 : 0.0),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Item de playlist en el sidebar desktop (px-3 py-2 text-sm text-secondary).
class _DesktopPlaylistItem extends StatelessWidget {
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  const _DesktopPlaylistItem({
    required this.title,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isSelected ? AppTheme.primary : AppTheme.secondary,
            fontSize: 14,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
