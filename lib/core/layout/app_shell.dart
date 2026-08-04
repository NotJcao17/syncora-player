import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

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
  double _sidebarWidth = 256.0;

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
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width >= 768;
    // Detectar celular en landscape: ancho >= 768 pero dimensión corta < 600
    final isMobileLandscape = isDesktop && size.shortestSide < 600;
    final selectedIndex = _calculateSelectedIndex();
    final isQueueOpen = ref.watch(isQueueOpenProvider);

    if (isDesktop) {
      return _buildDesktopLayout(context, selectedIndex, isQueueOpen, isMobileLandscape);
    } else {
      return _buildMobileLayout(context, selectedIndex);
    }
  }

  /// Layout Móvil (Android / pantallas < 768px)
  Widget _buildMobileLayout(BuildContext context, int selectedIndex) {
    final currentTrack = ref.watch(currentTrackProvider);
    final hasTrack = currentTrack != null;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: widget.child,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          color: hasTrack ? AppTheme.primary : Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MiniPlayer(),
              _MobileNavBar(
                selectedIndex: selectedIndex,
                onItemTapped: _onItemTapped,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Layout Desktop (Windows / pantallas >= 768px calcado de index.html mockup)
  Widget _buildDesktopLayout(BuildContext context, int selectedIndex, bool isQueueOpen, bool isMobileLandscape) {
    final sidebarWidth = _isSidebarCollapsed ? 80.0 : _sidebarWidth;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Column(
        children: [
          if (!kIsWeb && Platform.isWindows) const _CustomTitleBar(),
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
                  child: ClipRect(
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
                                            overflow: TextOverflow.clip,
                                            softWrap: false,
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

                        // Nav Items Principales (Lucide Icons)
                        _DesktopSidebarItem(
                          icon: LucideIcons.home,
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

                        const SizedBox(height: 20),

                        // Sección de Playlists: ocultar en celular landscape
                        if (!_isSidebarCollapsed && !isMobileLandscape)
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

                        // Lista de playlists: ocultar en celular landscape
                        if (!isMobileLandscape)
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
                          )
                        else
                          const Spacer(),
                      ],
                    ),
                  ),
                ),

                // Drag handle para redimensionar el sidebar (solo cuando expandido)
                if (!_isSidebarCollapsed)
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) {
                        setState(() {
                          _sidebarWidth = (_sidebarWidth + details.delta.dx).clamp(180.0, 400.0);
                        });
                      },
                      child: Container(
                        width: 5,
                        color: Colors.transparent,
                      ),
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

/// Barra de título personalizada para Windows (Estilo Spotify, frameless con controles de ventana y área de arrastre)
class _CustomTitleBar extends StatelessWidget {
  const _CustomTitleBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      color: AppTheme.background,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Container(
                color: Colors.transparent,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Image.asset(
                      'assets/icon/icon.png',
                      width: 18,
                      height: 18,
                      errorBuilder: (_, _, _) => const Icon(LucideIcons.music, color: AppTheme.primary, size: 16),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Syncora Player',
                      style: TextStyle(
                        color: AppTheme.secondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _WindowCaptionButton(
            icon: LucideIcons.minus,
            onPressed: () => windowManager.minimize(),
            hoverColor: AppTheme.surfaceHover,
          ),
          _WindowCaptionButton(
            icon: LucideIcons.square,
            onPressed: () async {
              if (await windowManager.isMaximized()) {
                windowManager.unmaximize();
              } else {
                windowManager.maximize();
              }
            },
            hoverColor: AppTheme.surfaceHover,
          ),
          _WindowCaptionButton(
            icon: LucideIcons.x,
            onPressed: () => windowManager.close(),
            hoverColor: const Color(0xFFE11D48),
          ),
        ],
      ),
    );
  }
}

class _WindowCaptionButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final Color hoverColor;

  const _WindowCaptionButton({
    required this.icon,
    required this.onPressed,
    required this.hoverColor,
  });

  @override
  State<_WindowCaptionButton> createState() => _WindowCaptionButtonState();
}

class _WindowCaptionButtonState extends State<_WindowCaptionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: 38,
          color: _isHovered ? widget.hoverColor : Colors.transparent,
          child: Icon(
            widget.icon,
            size: 14,
            color: AppTheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Nav bar móvil custom perfectamente centrada con íconos de Lucide.
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
              icon: LucideIcons.home,
              label: 'Inicio',
              isSelected: selectedIndex == 0,
              onTap: () => onItemTapped(0),
            ),
          ),
          Expanded(
            child: _NavDestination(
              icon: LucideIcons.search,
              label: 'Buscar',
              isSelected: selectedIndex == 1,
              onTap: () => onItemTapped(1),
            ),
          ),
          Expanded(
            child: _NavDestination(
              icon: LucideIcons.library,
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
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: color,
              size: 22,
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
      padding: const EdgeInsets.only(bottom: 6),
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 200),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 44,
            padding: EdgeInsets.symmetric(
              horizontal: isCollapsed ? 12 : 14,
            ),
            decoration: BoxDecoration(
              color: isSelected ? AppTheme.surfaceHover : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: isCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Icon(icon, color: color, size: 22),
                if (!isCollapsed) ...[
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
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

/// Item de playlist con miniatura estilo Spotify.
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
                        overflow: TextOverflow.clip,
                        softWrap: false,
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
                        overflow: TextOverflow.clip,
                        softWrap: false,
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
