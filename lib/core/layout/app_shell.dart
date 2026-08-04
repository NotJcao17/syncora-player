import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../features/player/player_providers.dart';
import '../../features/player/widgets/mini_player.dart';
import '../theme/app_theme.dart';

/// Layout adaptativo de la aplicación (Móvil vs Desktop calcado de los mockups HTML).
class AppShell extends ConsumerStatefulWidget {
  final Widget child;
  final String location;

  const AppShell({
    super.key,
    required this.child,
    required this.location,
  });

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _isSidebarCollapsed = false;

  int _calculateSelectedIndex() {
    if (widget.location.startsWith('/search')) return 1;
    if (widget.location.startsWith('/library')) return 2;
    return 0; // Default: Home '/'
  }

  void _onItemTapped(int index) {
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

  final List<Map<String, String>> _mockPlaylists = const [
    {
      'id': 'p1',
      'title': 'Synthwave Mix',
      'cover': 'https://images.unsplash.com/photo-1614613535308-eb5fbd3d2c17?q=80&w=200&auto=format&fit=crop',
    },
    {
      'id': 'p2',
      'title': 'Late Night Drive',
      'cover': 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?q=80&w=200&auto=format&fit=crop',
    },
    {
      'id': 'p3',
      'title': 'Focus 2026',
      'cover': 'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?q=80&w=200&auto=format&fit=crop',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final selectedIndex = _calculateSelectedIndex();
    final isQueueOpen = ref.watch(isQueueOpenProvider);

    if (isDesktop) {
      return _buildDesktopLayout(context, selectedIndex, isQueueOpen);
    } else {
      return _buildMobileLayout(context, selectedIndex);
    }
  }

  /// Layout Móvil (Android / pantallas < 768px)
  Widget _buildMobileLayout(BuildContext context, int selectedIndex) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: widget.child,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.translate(
              offset: const Offset(0, 24),
              child: const MiniPlayer(),
            ),
            _MobileNavBar(
              selectedIndex: selectedIndex,
              onItemTapped: _onItemTapped,
            ),
          ],
        ),
      ),
    );
  }

  /// Layout Desktop (Windows / pantallas >= 768px calcado de index.html mockup)
  Widget _buildDesktopLayout(BuildContext context, int selectedIndex, bool isQueueOpen) {
    final sidebarWidth = _isSidebarCollapsed ? 80.0 : 256.0;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Sidebar Izquierdo (256px expandido / 80px colapsado)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: sidebarWidth,
                  decoration: const BoxDecoration(
                    color: AppTheme.background,
                    border: Border(
                      right: BorderSide(color: AppTheme.surface, width: 1),
                    ),
                  ),
                  padding: EdgeInsets.all(_isSidebarCollapsed ? 8 : 16),
                  child: Column(
                    crossAxisAlignment: _isSidebarCollapsed
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    children: [
                      // Header del Sidebar: Logo 40x40 + Título con brillo + Toggle Colapsar
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Row(
                          mainAxisAlignment: _isSidebarCollapsed
                              ? MainAxisAlignment.center
                              : MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Container(
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      boxShadow: AppTheme.glowShadow,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: Image.asset(
                                        'assets/icon/icon.png',
                                        width: 36,
                                        height: 36,
                                        errorBuilder: (_, _, _) => Container(
                                          width: 36,
                                          height: 36,
                                          decoration: const BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: AppTheme.primary,
                                          ),
                                          child: const Icon(LucideIcons.music, color: AppTheme.background, size: 18),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (!_isSidebarCollapsed) ...[
                                    const SizedBox(width: 8),
                                    const Expanded(
                                      child: Text(
                                        'Syncora',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w900,
                                          color: AppTheme.primary,
                                          letterSpacing: -0.5,
                                          shadows: AppTheme.textGlow,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                _isSidebarCollapsed ? LucideIcons.panelLeftOpen : LucideIcons.panelLeftClose,
                                color: AppTheme.secondary,
                                size: 18,
                              ),
                              onPressed: () {
                                setState(() {
                                  _isSidebarCollapsed = !_isSidebarCollapsed;
                                });
                              },
                              tooltip: _isSidebarCollapsed ? 'Expandir panel' : 'Minimizar panel',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Nav Items Principales
                      _DesktopSidebarItem(
                        icon: LucideIcons.house,
                        label: 'Inicio',
                        isSelected: selectedIndex == 0,
                        isCollapsed: _isSidebarCollapsed,
                        onTap: () => _onItemTapped(0),
                      ),
                      _DesktopSidebarItem(
                        icon: LucideIcons.search,
                        label: 'Buscar',
                        isSelected: selectedIndex == 1,
                        isCollapsed: _isSidebarCollapsed,
                        onTap: () => _onItemTapped(1),
                      ),
                      _DesktopSidebarItem(
                        icon: LucideIcons.library,
                        label: 'Biblioteca',
                        isSelected: selectedIndex == 2,
                        isCollapsed: _isSidebarCollapsed,
                        onTap: () => _onItemTapped(2),
                      ),

                      const SizedBox(height: 24),

                      // Sección de Playlists con Miniaturas
                      if (!_isSidebarCollapsed)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'PLAYLISTS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: AppTheme.secondary,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),

                      Expanded(
                        child: ListView.builder(
                          itemCount: _mockPlaylists.length,
                          itemBuilder: (ctx, i) {
                            final pl = _mockPlaylists[i];
                            return _DesktopPlaylistItem(
                              title: pl['title']!,
                              coverUrl: pl['cover']!,
                              isSelected: widget.location.endsWith(pl['id']!),
                              isCollapsed: _isSidebarCollapsed,
                              onTap: () => context.push('/playlist/${pl['id']}'),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                // Área Central
                Expanded(
                  child: widget.child,
                ),

                // Panel Lateral Derecho de Cola de Reproducción en Windows
                if (isQueueOpen)
                  Container(
                    width: 320,
                    decoration: const BoxDecoration(
                      color: AppTheme.surface,
                      border: Border(
                        left: BorderSide(color: AppTheme.surfaceActive, width: 1),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Cola de reproducción',
                                style: TextStyle(
                                  color: AppTheme.primary,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(LucideIcons.x, color: AppTheme.secondary, size: 20),
                                onPressed: () {
                                  ref.read(isQueueOpenProvider.notifier).state = false;
                                },
                              ),
                            ],
                          ),
                        ),
                        const Divider(color: AppTheme.surfaceActive, height: 1),
                        Expanded(
                          child: _buildQueueList(ref),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // MiniPlayer continuo de ancho completo
          const MiniPlayer(),
        ],
      ),
    );
  }

  Widget _buildQueueList(WidgetRef ref) {
    final state = ref.watch(playerStateProvider);
    final queue = state.queue;
    final currentIndex = state.currentIndex;

    if (queue.isEmpty) {
      return const Center(
        child: Text(
          'La cola está vacía',
          style: TextStyle(color: AppTheme.secondary),
        ),
      );
    }

    return ListView.builder(
      itemCount: queue.length,
      itemBuilder: (ctx, i) {
        final track = queue[i];
        final isCurrent = i == currentIndex;

        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CachedNetworkImage(
              imageUrl: track.coverUrl,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => Container(
                color: AppTheme.surfaceHover,
                child: const Icon(LucideIcons.music, color: AppTheme.muted, size: 16),
              ),
            ),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isCurrent ? AppTheme.primary : AppTheme.primary.withValues(alpha: 0.9),
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              fontSize: 13,
            ),
          ),
          subtitle: Text(
            track.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTheme.secondary, fontSize: 11),
          ),
          trailing: isCurrent
              ? const Icon(LucideIcons.chartColumn, color: AppTheme.primary, size: 16)
              : null,
          onTap: () {
            ref.read(syncoraPlayerControllerProvider.notifier).skipToQueueIndex(i);
          },
        );
      },
    );
  }
}

/// Nav bar móvil custom centrada.
class _MobileNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemTapped;

  const _MobileNavBar({required this.selectedIndex, required this.onItemTapped});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: AppTheme.bottomNavShadow,
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
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

/// Destino individual de la nav bar móvil centrado.
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
    final color = isSelected ? AppTheme.primary : AppTheme.secondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
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
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Item del sidebar desktop.
class _DesktopSidebarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final bool isCollapsed;
  final VoidCallback onTap;

  const _DesktopSidebarItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.isCollapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppTheme.primary : AppTheme.secondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 200),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: isCollapsed ? 12 : 14,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: isSelected ? AppTheme.surfaceHover : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: isCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Icon(icon, color: color, size: 22, fill: isSelected ? 1.0 : 0.0),
                if (!isCollapsed) ...[
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Item de playlist con miniatura en el sidebar desktop.
class _DesktopPlaylistItem extends StatelessWidget {
  final String title;
  final String coverUrl;
  final bool isSelected;
  final bool isCollapsed;
  final VoidCallback onTap;

  const _DesktopPlaylistItem({
    required this.title,
    required this.coverUrl,
    required this.isSelected,
    required this.isCollapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: title,
      waitDuration: const Duration(milliseconds: 200),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisAlignment: isCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: coverUrl,
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                ),
              ),
              if (!isCollapsed) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected ? AppTheme.primary : AppTheme.secondary,
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
