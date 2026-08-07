import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../navigation/app_router.dart';
import '../theme/app_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/local_db/database_provider.dart';
import '../../data/local_db/syncora_database.dart';
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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width >= 768;
    // Detectar celular en landscape: ancho >= 768 pero dimensión corta < 600
    final isMobileLandscape = isDesktop && size.shortestSide < 600;
    final selectedIndex = _calculateSelectedIndex();
    final isQueueOpen = ref.watch(isQueueOpenProvider);

    final childWidget = isDesktop
        ? _buildDesktopLayout(context, selectedIndex, isQueueOpen, isMobileLandscape)
        : _buildMobileLayout(context, selectedIndex);

    return Listener(
      onPointerDown: (PointerDownEvent event) {
        if (event.kind == PointerDeviceKind.mouse &&
            (event.buttons == kBackMouseButton || (event.buttons & kBackMouseButton != 0))) {
          final router = ref.read(appRouterProvider);
          if (router.canPop()) {
            router.pop();
          }
        }
      },
      child: childWidget,
    );
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            _MobileNavBar(
              selectedIndex: selectedIndex,
              onItemTapped: _onItemTapped,
              hasTrack: hasTrack,
            ),
          ],
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
                              icon: Icon(AppIcons.broken(SolarIcons.SidebarMinimalistic), color: AppTheme.secondary, size: 22),
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
                                          errorBuilder: (_, _, _) => Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.primary, size: 24),
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
                                  icon: Icon(AppIcons.broken(SolarIcons.SidebarMinimalistic), color: AppTheme.secondary, size: 18),
                                  onPressed: () => setState(() => _isSidebarCollapsed = true),
                                  tooltip: 'Minimizar panel',
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 20),

                        // Nav Items Principales (Solar Icons)
                        _DesktopSidebarItem(
                          icon: AppIcons.broken(SolarIcons.HomeInEssentionalUI),
                          selectedIcon: AppIcons.bold(SolarIcons.HomeInEssentionalUI),
                          label: 'Inicio',
                          isSelected: selectedIndex == 0,
                          isCollapsed: _isSidebarCollapsed,
                          onTap: () => _onItemTapped(0),
                        ),
                        _DesktopSidebarItem(
                          icon: AppIcons.broken(SolarIcons.Magnifer),
                          selectedIcon: AppIcons.bold(SolarIcons.Magnifer),
                          label: 'Buscar',
                          isSelected: selectedIndex == 1,
                          isCollapsed: _isSidebarCollapsed,
                          onTap: () => _onItemTapped(1),
                        ),
                        _DesktopSidebarItem(
                          icon: AppIcons.broken(SolarIcons.Library),
                          selectedIcon: AppIcons.bold(SolarIcons.Library),
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

                        // Lista de playlists real desde Drift DB
                        if (!isMobileLandscape)
                          Expanded(
                            child: Consumer(
                              builder: (ctx, ref, _) {
                                final playlistDao = ref.watch(playlistDaoProvider);
                                return StreamBuilder<List<Playlist>>(
                                  stream: playlistDao.watchAllPlaylists(),
                                  builder: (ctx, snapshot) {
                                    final playlists = snapshot.data ?? [];
                                    if (playlists.isEmpty) {
                                      return const Center(
                                        child: Text(
                                          'Sin playlists',
                                          style: TextStyle(color: AppTheme.secondary, fontSize: 12),
                                        ),
                                      );
                                    }

                                    final playerState = ref.watch(playerStateProvider);
                                    final activeContextId = playerState.activeContextId;

                                    return ListView.builder(
                                      itemCount: playlists.length,
                                      itemBuilder: (ctx, i) {
                                        final pl = playlists[i];
                                        final isSelected = widget.location.endsWith('/playlist/${pl.id}') ||
                                            (pl.isLiked && widget.location.endsWith('/playlist/liked'));
                                        final isActivelyPlaying = activeContextId == 'playlist_${pl.id}';

                                        return _DesktopPlaylistItem(
                                          title: pl.title,
                                          subtitle: pl.isLiked ? 'Playlist especial' : (pl.description ?? 'Playlist'),
                                          coverUrl: pl.coverUrl ?? '',
                                          isLiked: pl.isLiked,
                                          isSelected: isSelected,
                                          isActivelyPlaying: isActivelyPlaying,
                                          isCollapsed: _isSidebarCollapsed,
                                          onTap: () => context.push('/playlist/${pl.isLiked ? 'liked' : pl.id}'),
                                        );
                                      },
                                    );
                                  },
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
                                icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary, size: 20),
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
                child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 16),
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
              ? Icon(AppIcons.broken(SolarIcons.Chart), color: AppTheme.primary, size: 16)
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
                      errorBuilder: (_, _, _) => Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.primary, size: 16),
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
            icon: AppIcons.broken(SolarIcons.MinusSquare),
            onPressed: () => windowManager.minimize(),
            hoverColor: AppTheme.surfaceHover,
          ),
          _WindowCaptionButton(
            icon: AppIcons.broken(SolarIcons.MaximizeSquare),
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
            icon: AppIcons.broken(SolarIcons.CloseSquare),
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
            size: 19,
            color: AppTheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Nav bar móvil custom perfectamente centrada con íconos de Solar.
class _MobileNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemTapped;
  final bool hasTrack;

  const _MobileNavBar({
    required this.selectedIndex,
    required this.onItemTapped,
    this.hasTrack = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: hasTrack ? AppTheme.primary : Colors.transparent,
      child: Container(
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
              icon: AppIcons.broken(SolarIcons.HomeInEssentionalUI),
              selectedIcon: AppIcons.bold(SolarIcons.HomeInEssentionalUI),
              label: 'Inicio',
              isSelected: selectedIndex == 0,
              onTap: () => onItemTapped(0),
            ),
          ),
          Expanded(
            child: _NavDestination(
              icon: AppIcons.broken(SolarIcons.Magnifer),
              selectedIcon: AppIcons.bold(SolarIcons.Magnifer),
              label: 'Buscar',
              isSelected: selectedIndex == 1,
              onTap: () => onItemTapped(1),
            ),
          ),
          Expanded(
            child: _NavDestination(
              icon: AppIcons.broken(SolarIcons.Library),
              selectedIcon: AppIcons.bold(SolarIcons.Library),
              label: 'Biblioteca',
              isSelected: selectedIndex == 2,
              onTap: () => onItemTapped(2),
            ),
          ),
        ],
      ),
    ),
  );
}
}

/// Destino individual centrado horizontal y verticalmente.
class _NavDestination extends StatelessWidget {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavDestination({
    required this.icon,
    this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppTheme.primary : AppTheme.secondary;
    final currentIcon = isSelected ? (selectedIcon ?? icon) : icon;

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
              currentIcon,
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
  final IconData? selectedIcon;
  final String label;
  final bool isSelected;
  final bool isCollapsed;
  final VoidCallback onTap;

  const _DesktopSidebarItem({
    required this.icon,
    this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.isCollapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppTheme.primary : AppTheme.secondary;
    final currentIcon = isSelected ? (selectedIcon ?? icon) : icon;

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
                Icon(currentIcon, color: color, size: 22),
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
class _DesktopPlaylistItem extends StatefulWidget {
  final String title;
  final String subtitle;
  final String coverUrl;
  final bool isLiked;
  final bool isSelected;
  final bool isActivelyPlaying;
  final bool isCollapsed;
  final VoidCallback onTap;

  const _DesktopPlaylistItem({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    this.isLiked = false,
    required this.isSelected,
    this.isActivelyPlaying = false,
    required this.isCollapsed,
    required this.onTap,
  });

  @override
  State<_DesktopPlaylistItem> createState() => _DesktopPlaylistItemState();
}

class _DesktopPlaylistItemState extends State<_DesktopPlaylistItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.title,
      waitDuration: const Duration(milliseconds: 200),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? AppTheme.surfaceHover
                  : (_isHovered ? AppTheme.surfaceHover.withValues(alpha: 0.5) : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              mainAxisAlignment: widget.isCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: widget.isLiked
                        ? Container(
                            decoration: const BoxDecoration(gradient: AppTheme.gradientLiked),
                            child: Icon(AppIcons.bold(SolarIcons.Heart), color: Colors.white, size: 22),
                          )
                        : (widget.coverUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: widget.coverUrl,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => Container(color: AppTheme.surfaceHover, child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 20)),
                              )
                            : Container(color: AppTheme.surfaceHover, child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 20))),
                  ),
                ),
                if (!widget.isCollapsed) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          softWrap: false,
                          style: const TextStyle(
                            color: AppTheme.primary,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
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
                  if (widget.isActivelyPlaying)
                    Icon(AppIcons.broken(SolarIcons.VolumeLoud), color: const Color(0xFF22C55E), size: 18),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
