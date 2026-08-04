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
      'title': '2026',
      'subtitle': 'Playlist • Syncora',
      'cover': 'https://images.unsplash.com/photo-1614613535308-eb5fbd3d2c17?q=80&w=200&auto=format&fit=crop',
    },
    {
      'id': 'p2',
      'title': 'ACÚSTICAS',
      'subtitle': 'Playlist • Syncora',
      'cover': 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?q=80&w=200&auto=format&fit=crop',
    },
    {
      'id': 'p3',
      'title': 'CHILL',
      'subtitle': 'Playlist • Syncora',
      'cover': 'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?q=80&w=200&auto=format&fit=crop',
    },
    {
      'id': 'p4',
      'title': 'COVERS',
      'subtitle': 'Playlist • Syncora',
      'cover': 'https://images.unsplash.com/photo-1493225457124-a1a2a5f529a8?q=80&w=200&auto=format&fit=crop',
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
                      // Header del Sidebar
                      if (_isSidebarCollapsed)
                        Center(
                          child: IconButton(
                            icon: const Icon(LucideIcons.panelLeftOpen, color: AppTheme.secondary, size: 22),
                            onPressed: () => setState(() => _isSidebarCollapsed = false),
                            tooltip: 'Expandir panel',
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onTap: () => context.go('/'),
                                  child: Row(
                                    children: [
                                      Image.asset(
                                        'assets/icon/icon.png',
                                        width: 32,
                                        height: 32,
                                        errorBuilder: (_, _, _) => const Icon(LucideIcons.music, color: AppTheme.primary, size: 24),
                                      ),
                                      const SizedBox(width: 8),
                                      const Flexible(
                                        child: Text(
                                          'Syncora',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w900,
                                            color: AppTheme.primary,
                                            letterSpacing: -0.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(LucideIcons.panelLeftClose, color: AppTheme.secondary, size: 18),
                                onPressed: () => setState(() => _isSidebarCollapsed = true),
                                tooltip: 'Minimizar panel',
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 20),

                      // Nav Items Principales (Íconos rellenos como Imagen 3)
                      _DesktopSidebarItem(
                        selectedIcon: Icons.home_rounded,
                        unselectedIcon: Icons.home_outlined,
                        label: 'Inicio',
                        isSelected: selectedIndex == 0,
                        isCollapsed: _isSidebarCollapsed,
                        onTap: () => _onItemTapped(0),
                      ),
                      _DesktopSidebarItem(
                        selectedIcon: Icons.search_rounded,
                        unselectedIcon: Icons.search_rounded,
                        label: 'Buscar',
                        isSelected: selectedIndex == 1,
                        isCollapsed: _isSidebarCollapsed,
                        onTap: () => _onItemTapped(1),
                      ),
                      _DesktopSidebarItem(
                        selectedIcon: Icons.collections_bookmark_rounded,
                        unselectedIcon: Icons.collections_bookmark_outlined,
                        label: 'Biblioteca',
                        isSelected: selectedIndex == 2,
                        isCollapsed: _isSidebarCollapsed,
                        onTap: () => _onItemTapped(2),
                      ),

                      const SizedBox(height: 20),

                      // Sección de Playlists estilo Spotify (Imagen 1)
                      if (!_isSidebarCollapsed)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                      const SizedBox(height: 8),

                      Expanded(
                        child: ListView.builder(
                          itemCount: _mockPlaylists.length,
                          itemBuilder: (ctx, i) {
                            final pl = _mockPlaylists[i];
                            final isPlaying = widget.location.endsWith(pl['id']!);

                            return _DesktopPlaylistItem(
                              title: pl['title']!,
                              subtitle: pl['subtitle']!,
                              coverUrl: pl['cover']!,
                              isSelected: isPlaying,
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

/// Nav bar móvil custom perfectamente centrada con íconos rellenos (Imagen 3).
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
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: _NavDestination(
              selectedIcon: Icons.home_rounded,
              unselectedIcon: Icons.home_outlined,
              label: 'Inicio',
              isSelected: selectedIndex == 0,
              onTap: () => onItemTapped(0),
            ),
          ),
          Expanded(
            child: _NavDestination(
              selectedIcon: Icons.search_rounded,
              unselectedIcon: Icons.search_rounded,
              label: 'Buscar',
              isSelected: selectedIndex == 1,
              onTap: () => onItemTapped(1),
            ),
          ),
          Expanded(
            child: _NavDestination(
              selectedIcon: Icons.collections_bookmark_rounded,
              unselectedIcon: Icons.collections_bookmark_outlined,
              label: 'Biblioteca',
              isSelected: selectedIndex == 2,
              onTap: () => onItemTapped(2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Destino individual centrado horizontal y verticalmente.
class _NavDestination extends StatelessWidget {
  final IconData selectedIcon;
  final IconData unselectedIcon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavDestination({
    required this.selectedIcon,
    required this.unselectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppTheme.primary : AppTheme.secondary;
    final iconData = isSelected ? selectedIcon : unselectedIcon;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              iconData,
              color: color,
              size: 24,
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
  final IconData selectedIcon;
  final IconData unselectedIcon;
  final String label;
  final bool isSelected;
  final bool isCollapsed;
  final VoidCallback onTap;

  const _DesktopSidebarItem({
    required this.selectedIcon,
    required this.unselectedIcon,
    required this.label,
    required this.isSelected,
    required this.isCollapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppTheme.primary : AppTheme.secondary;
    final iconData = isSelected ? selectedIcon : unselectedIcon;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
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
                Icon(iconData, color: color, size: 22),
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

/// Item de playlist con miniatura estilo Spotify (Imagen 1: 48x48 miniatura, título, subtitle y parlante si reproduce).
class _DesktopPlaylistItem extends StatelessWidget {
  final String title;
  final String subtitle;
  final String coverUrl;
  final bool isSelected;
  final bool isCollapsed;
  final VoidCallback onTap;

  const _DesktopPlaylistItem({
    required this.title,
    required this.subtitle,
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
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisAlignment: isCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: coverUrl,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                ),
              ),
              if (!isCollapsed) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isSelected ? const Color(0xFF22C55E) : AppTheme.primary,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  const Icon(LucideIcons.volume2, color: Color(0xFF22C55E), size: 18),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
