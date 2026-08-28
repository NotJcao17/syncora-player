import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../navigation/app_router.dart';
import '../theme/app_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/local_db/database_provider.dart';
import '../../data/local_db/syncora_database.dart';
import '../../data/sync/sync_service.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/local_mode_provider.dart';
import '../../features/download/download_provider.dart';
import '../../features/player/player_models.dart';
import '../../features/player/player_providers.dart';
import '../../features/player/syncora_player_controller.dart';
import '../../features/player/widgets/desktop_lyrics_view.dart';
import '../../features/player/widgets/mini_player.dart';
import '../../features/player/widgets/queue_view.dart';
import '../theme/app_theme.dart';
import '../utils/connectivity_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/offline_banner.dart';
import '../widgets/playlist_cover_widget.dart';

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

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      HardwareKeyboard.instance.addHandler(_handleDesktopKeyEvent);
    }
    Future.microtask(() async {
      // Inicializar downloadService y ejecutar limpieza de descargas interrumpidas
      ref.read(downloadServiceProvider);

      final isLocalMode = ref.read(localModeProvider);
      final isConnected = ref.read(isConnectedProvider).value ?? true;
      final user = ref.read(currentUserProvider);
      if (!isLocalMode && isConnected && user != null) {
        try {
          await ref.read(syncServiceProvider).syncLibrary(force: false);
          await ref.read(syncServiceProvider).syncSavedAlbums(force: false);
        } catch (_) {}
      }
    });
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) {
      if (ref.read(isLyricsOpenProvider)) {
        ref.read(isLyricsOpenProvider.notifier).state = false;
      }
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      HardwareKeyboard.instance.removeHandler(_handleDesktopKeyEvent);
    }
    super.dispose();
  }

  bool _handleDesktopKeyEvent(KeyEvent event) {
    // 1. Teclas multimedia de teclado físico (capturar y consumir el evento para no reactivar otras apps)
    final isMediaKey = event.logicalKey == LogicalKeyboardKey.mediaPlayPause ||
        event.logicalKey == LogicalKeyboardKey.mediaPlay ||
        event.logicalKey == LogicalKeyboardKey.mediaPause ||
        event.logicalKey == LogicalKeyboardKey.mediaTrackNext ||
        event.logicalKey == LogicalKeyboardKey.mediaTrackPrevious ||
        event.logicalKey == LogicalKeyboardKey.mediaStop;

    if (isMediaKey) {
      // En Windows, `WindowsMediaControls` (SMTC) ya es el único camino que
      // debe reaccionar a estas teclas: `SystemMediaTransportControls`
      // recibe la pulsación a nivel de SO incluso con la ventana de Syncora
      // sin foco, cosa que este handler de `HardwareKeyboard` no puede (solo
      // ve la tecla cuando la ventana SÍ tiene foco). Si este handler
      // también actuara aquí, una sola pulsación con la ventana enfocada
      // alternaría play/pause DOS veces dentro de la propia app (SMTC +
      // este handler), cancelándose entre sí. Sigue consumiendo el evento
      // (`return true`) para no dejarlo escapar hacia otro atajo de Flutter.
      // En Linux/macOS no hay un equivalente de SMTC en este código todavía,
      // así que ahí este handler sigue siendo el único camino.
      if (!Platform.isWindows && event is KeyDownEvent) {
        final controller = ref.read(syncoraPlayerControllerProvider);
        if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause ||
            event.logicalKey == LogicalKeyboardKey.mediaPlay) {
          if (controller.state.currentTrack != null) {
            if (controller.state.engine.playing) {
              controller.pause();
            } else {
              controller.play();
            }
          }
        } else if (event.logicalKey == LogicalKeyboardKey.mediaPause) {
          controller.pause();
        } else if (event.logicalKey == LogicalKeyboardKey.mediaTrackNext) {
          controller.skipToNext();
        } else if (event.logicalKey == LogicalKeyboardKey.mediaTrackPrevious) {
          controller.skipToPrevious();
        } else if (event.logicalKey == LogicalKeyboardKey.mediaStop) {
          controller.stop();
        }
      }
      return true;
    }

    if (event is! KeyDownEvent) return false;

    // 2. Barra espaciadora: toggle Play/Pause si no se está escribiendo en un input
    if (event.logicalKey == LogicalKeyboardKey.space) {
      final primaryFocus = FocusManager.instance.primaryFocus;
      final focusContext = primaryFocus?.context;
      if (focusContext != null) {
        final isEditable = focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
        if (isEditable) return false;
      }

      final controller = ref.read(syncoraPlayerControllerProvider);
      if (controller.state.currentTrack == null) return false;

      if (controller.state.engine.playing) {
        controller.pause();
      } else {
        controller.play();
      }
      return true;
    }

    return false;
  }

  int _calculateSelectedIndex() {
    if (widget.location.startsWith('/search')) return 1;
    if (widget.location.startsWith('/library')) return 2;
    return 0; // Default: Home '/'
  }

  void _onItemTapped(int index) {
    ref.read(isLyricsOpenProvider.notifier).state = false;
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

    // Fase 7.C (toast de auto-skip lógico) + H-6 (aviso de pausa por
    // 403/red persistente, diseñado en la Fase 1 pero nunca cableado a la
    // UI). AppShell envuelve toda la app y siempre está montado, así que es
    // el punto de escucha natural (ver docs/plan_fase_7.md, hallazgo H-6).
    // `PlayerNotice.id` es monotónico: comparar contra el `id` anterior es
    // lo que evita repetir el mismo aviso en cada rebuild sin necesidad de
    // "limpiar" el campo después de mostrarlo.
    ref.listen<SyncoraPlayerState>(playerStateProvider, (previous, next) {
      final notice = next.notice;
      if (notice == null) return;
      if (previous?.notice?.id == notice.id) return;

      switch (notice.kind) {
        case PlayerNoticeKind.logicalSkip:
          // 7.C.1: "{título} no disponible — saltada". Nunca se dispara
          // para el skip manual del usuario ni para el salto silencioso
          // offline — ninguno de los dos pasa por _handleExtractionError.
          AppToast.show(context, message: notice.message);
          break;
        case PlayerNoticeKind.cascadeGuard:
          // 7.C.3: guard de cascada tras 3 fallos lógicos seguidos. El
          // motor ya quedó pausado; "Reintentar" resetea el contador y
          // vuelve a intentar avanzar. No tocar nada equivale a "pausar".
          AppToast.show(
            context,
            message: notice.message,
            actionLabel: 'Reintentar',
            onAction: () {
              ref.read(syncoraPlayerControllerProvider.notifier).resumeAfterCascadeGuard();
            },
            duration: const Duration(seconds: 6),
          );
          break;
        case PlayerNoticeKind.persistentError:
          // H-6: pausa por error persistente (403/red) tras 1 reintento —
          // la pausa ya funcionaba desde la Fase 1, este aviso es lo que
          // faltaba conectar. Mensaje propio del controlador, distinto al
          // de logicalSkip (acá no hubo ningún skip).
          AppToast.show(context, message: notice.message, duration: const Duration(seconds: 5));
          break;
      }
    });

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
    final paddingBottom = MediaQuery.of(context).padding.bottom;
    return Stack(

      children: [
        Scaffold(
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
        ),
        Positioned(
          bottom: (hasTrack ? 152.0 : 80.0) + paddingBottom,
          left: 0,
          right: 0,
          child: const Center(
            child: OfflineBanner(),
          ),
        ),

      ],
    );
  }


  /// Layout Desktop (Windows / pantallas >= 768px calcado de index.html mockup)
  Widget _buildDesktopLayout(BuildContext context, int selectedIndex, bool isQueueOpen, bool isMobileLandscape) {
    final sidebarWidth = _isSidebarCollapsed ? 80.0 : _sidebarWidth;
    final isLyricsOpen = ref.watch(isLyricsOpenProvider);
    final currentTrack = ref.watch(currentTrackProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          Column(
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
                                    onTap: () {
                                      ref.read(isLyricsOpenProvider.notifier).state = false;
                                      context.go('/');
                                    },
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
                                            overflow: TextOverflow.ellipsis,
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

                                    final activeContextId = ref.watch(playerStateProvider.select((s) => s.activeContextId));

                                    return ListView.builder(
                                      itemCount: playlists.length,
                                      itemBuilder: (ctx, i) {
                                        final pl = playlists[i];
                                        final isSelected = widget.location.endsWith('/playlist/${pl.id}') ||
                                            (pl.isLiked && widget.location.endsWith('/playlist/liked'));
                                        final isActivelyPlaying = activeContextId == 'playlist_${pl.id}';

                                        return _DesktopPlaylistItem(
                                          playlistId: pl.id,
                                          title: pl.title,
                                          subtitle: pl.isLiked ? 'Playlist especial' : (pl.description ?? 'Playlist'),
                                          coverUrl: pl.coverUrl ?? '',
                                          isLiked: pl.isLiked,
                                          isSelected: isSelected,
                                          isActivelyPlaying: isActivelyPlaying,
                                          isCollapsed: _isSidebarCollapsed,
                                          onTap: () {
                                            ref.read(isLyricsOpenProvider.notifier).state = false;
                                            context.push('/playlist/${pl.isLiked ? 'liked' : pl.id}');
                                          },
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
                  child: (isLyricsOpen && currentTrack != null)
                      ? DesktopLyricsView(track: currentTrack)
                      : widget.child,
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
                        const Expanded(
                          child: QueueView(),
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
      Positioned(
        bottom: 104,
        left: 0,
        right: 0,
        child: const Center(
          child: OfflineBanner(),
        ),
      ),
    ],
  ),
);

  }

}

/// Barra de título personalizada para Windows (Estilo Spotify, frameless con controles de ventana y área de arrastre)
class _CustomTitleBar extends ConsumerWidget {
  const _CustomTitleBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final isLocalMode = ref.watch(localModeProvider);
    final profileAsync = ref.watch(profileProvider);
    // 7.I.4: en modo local no hay `profiles.avatar_seed` -- se usa la
    // semilla local generada por `LocalModeStorage.getOrCreateAvatarSeed()`.
    final localSeedAsync = isLocalMode ? ref.watch(localAvatarSeedProvider) : null;
    final seed = isLocalMode
        ? (localSeedAsync?.value ?? 'default-seed')
        : (profileAsync.value?['avatar_seed'] ?? user?.id ?? 'default-seed');

    return Container(
      height: 42,
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
          // Fase 7.I: en modo local no hay `user`, pero sigue habiendo una
          // Configuración a la que llegar desde desktop (antes este popup
          // -- y con él, la única entrada de escritorio a Configuración --
          // desaparecía por completo sin cuenta). "Cerrar sesión" sí se
          // oculta (7.I.8): no hay sesión que cerrar.
          if (user != null || isLocalMode)
            PopupMenuButton<String>(
              tooltip: 'Mi Perfil',
              color: AppTheme.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              offset: const Offset(0, 38),
              onSelected: (value) async {
                if (value == 'settings') {
                  context.push('/settings');
                } else if (value == 'logout') {
                  try {
                    await Supabase.instance.client.auth.signOut();
                  } catch (_) {}
                  if (context.mounted) context.go('/auth');
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'settings',
                  child: Row(
                    children: [
                      Icon(AppIcons.broken(SolarIcons.User), color: AppTheme.primary, size: 18),
                      const SizedBox(width: 10),
                      const Text('Mi cuenta', style: TextStyle(color: AppTheme.primary, fontSize: 13)),
                    ],
                  ),
                ),
                if (!isLocalMode)
                  PopupMenuItem(
                    value: 'logout',
                    child: Row(
                      children: [
                        Icon(AppIcons.broken(SolarIcons.Logout), color: Colors.redAccent, size: 18),
                        const SizedBox(width: 10),
                        const Text('Cerrar sesión', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                      ],
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 28,
                    height: 28,
                    color: AppTheme.surfaceActive,
                    child: SvgPicture.network(
                      'https://api.dicebear.com/9.x/adventurer-neutral/svg?seed=$seed',
                      fit: BoxFit.cover,
                      placeholderBuilder: (_) => Icon(AppIcons.broken(SolarIcons.User), color: AppTheme.muted, size: 16),
                    ),
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
                      overflow: TextOverflow.ellipsis,
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
  final int? playlistId;
  final String title;
  final String subtitle;
  final String coverUrl;
  final bool isLiked;
  final bool isSelected;
  final bool isActivelyPlaying;
  final bool isCollapsed;
  final VoidCallback onTap;

  const _DesktopPlaylistItem({
    this.playlistId,
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
                    child: PlaylistCoverWidget(
                      playlistId: widget.playlistId,
                      coverUrl: widget.coverUrl,
                      isLiked: widget.isLiked,
                      width: 48,
                      height: 48,
                      borderRadius: BorderRadius.circular(8),
                      memCacheWidth: 100,
                      memCacheHeight: 100,
                    ),
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
                          overflow: TextOverflow.ellipsis,
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
                          overflow: TextOverflow.ellipsis,
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
                    Padding(
                      padding: const EdgeInsets.only(left: 8.0),
                      child: Icon(AppIcons.broken(SolarIcons.VolumeLoud), color: Colors.white, size: 18),
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
