import 'bottom_chrome_metrics.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../navigation/app_router.dart';
import '../theme/app_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/local_db/database_provider.dart';
import '../../data/local_db/duplicate_repair.dart';
import '../../data/local_db/syncora_database.dart';
import '../../data/sync/sync_service.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/local_mode_provider.dart';
import '../../features/profile/widgets/user_avatar.dart';
import '../../features/download/download_provider.dart';
import '../../features/stats/genre_backfill_service.dart';
import '../../features/home/mixes/on_repeat_service.dart';
import '../../features/library/import_export/import_manager.dart';
import '../../features/library/library_folders.dart';
import '../../features/library/library_view_settings.dart';
import '../../features/library/services/folder_service.dart';
import '../../features/library/widgets/folder_widgets.dart';
import '../../features/player/player_models.dart';
import '../../features/player/player_providers.dart';
import '../../features/player/syncora_player_controller.dart';
import '../../features/player/widgets/desktop_lyrics_view.dart';
import '../../features/player/widgets/mini_player.dart';
import '../../features/player/widgets/queue_view.dart';
import '../theme/app_theme.dart';
import '../cache/cover_repair_service.dart';
import 'keyboard_inset_freeze.dart';
import '../utils/connectivity_service.dart';
import '../utils/startup_retry.dart';
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

  /// Carpetas desplegadas en la barra lateral (Fase 8.E). Solo de la sesión.
  final Set<int> _expandedSidebarFolders = {};

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      HardwareKeyboard.instance.addHandler(_handleDesktopKeyEvent);
    }
    Future.microtask(() async {
      // Inicializar downloadService y ejecutar limpieza de descargas interrumpidas
      ref.read(downloadServiceProvider);
      // Ronda 4: reanuda las importaciones que quedaron a medias al cerrar
      // la app (el gestor carga sus trabajos de disco al crearse).
      ref.read(importManagerProvider);

      // Sana la base local antes de sincronizar nada: si una versión anterior
      // dejó playlists o pistas duplicadas (ver `PlaylistDao.repairDuplicates`),
      // arreglarlas acá es lo que hace que el usuario no tenga que borrar los
      // datos de la app a mano.
      //
      // **Una sola pasada, no en cada arranque.** La causa (corridas
      // simultáneas de `syncLibrary`) ya está cerrada con la guarda de
      // reentrancia de `SyncService`, así que esto es una limpieza de una vez
      // para las instalaciones que quedaron sucias con las versiones
      // anteriores, no una red de seguridad permanente.
      await ref.read(duplicateRepairProvider).runOnce();

      final isLocalMode = ref.read(localModeProvider);
      final isConnected = ref.read(isConnectedProvider).value ?? true;
      final user = ref.read(currentUserProvider);
      if (!isLocalMode && isConnected && user != null) {
        // Con reintento: en el arranque en frío el DNS todavía no resuelve, así
        // que este primer sync moría en silencio y los cambios hechos en otro
        // dispositivo no aparecían hasta recargar a mano.
        try {
          // `shouldRetry` corta el presupuesto si la red se cae a mitad del
          // arranque, en vez de seguir reintentando 15 s contra nada.
          bool networkStillPlausible() => ref.read(isConnectedProvider).value ?? true;
          await retryOnNetworkError(
            () => ref.read(syncServiceProvider).syncLibrary(force: false),
            shouldRetry: networkStillPlausible,
          );
          await retryOnNetworkError(
            () => ref.read(syncServiceProvider).syncSavedAlbums(force: false),
            shouldRetry: networkStillPlausible,
          );
          // Antes que "On Repeat": el historial ahora también se BAJA de la
          // nube, y sin esperar a eso cada dispositivo generaría su playlist
          // solo con lo que se escuchó ahí — que era justamente el problema.
          await retryOnNetworkError(
            () => ref.read(syncServiceProvider).syncListeningHistory(),
            shouldRetry: networkStillPlausible,
          );
        } catch (_) {}
      }

      // "On Repeat" se genera en el arranque, no al abrir Inicio: es una
      // playlist de la biblioteca, así que tiene que existir aunque el usuario
      // entre directo a Biblioteca.
      try {
        await ref.read(onRepeatPlaylistProvider.future);
      } catch (_) {}

      // Ronda 4: portadas que Deezer dio de baja (una vez por semana, en
      // segundo plano, después del sync para no competir con él).
      if (ref.read(isConnectedProvider).value ?? true) {
        unawaited(ref.read(coverRepairServiceProvider).runIfDue());
      }

      // H-S6: rellena en segundo plano el género de las escuchas que no lo
      // tienen (ninguna, hasta esta corrección). Va al final y sin `await`
      // porque no bloquea nada de lo que el usuario ve: son peticiones a
      // Deezer por álbum, cacheadas para siempre, y lo que no alcance a
      // resolver esta vez lo resuelve el próximo arranque. Después empuja el
      // resultado, que el relleno deja marcado como pendiente de subir.
      unawaited(() async {
        final filled = await ref.read(genreBackfillServiceProvider).run();
        if (filled > 0 && !ref.read(localModeProvider)) {
          await ref.read(syncServiceProvider).syncListeningHistory();
        }
      }());
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
    final size = MediaQuery.sizeOf(context);
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
        case PlayerNoticeKind.blockedOffline:
          // Acción pedida desde un control del SO (pantalla de bloqueo /
          // barra de tareas) que necesita internet. Ahí no hay botón que
          // deshabilitar, así que el aviso llega por acá.
          AppToast.show(context, message: notice.message);
          break;
        case PlayerNoticeKind.engineBroken:
        case PlayerNoticeKind.engineRecovered:
          // Fase 8.A: motor de extracción roto / recuperado. El detalle (qué
          // motor, cuándo se buscó) vive en Configuración → Motor.
          AppToast.show(context, message: notice.message, duration: const Duration(seconds: 6));
          break;
        case PlayerNoticeKind.engineNoFix:
          AppToast.show(
            context,
            message: notice.message,
            actionLabel: 'Reintentar',
            onAction: () {
              ref.read(syncoraPlayerControllerProvider.notifier).play();
            },
            duration: const Duration(seconds: 8),
          );
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
      // H-R5-7: con una hoja encima, el shell no sigue al teclado.
      child: KeyboardInsetFreeze(child: childWidget),
    );
  }

  /// Layout Móvil (Android / pantallas < 768px)
  Widget _buildMobileLayout(BuildContext context, int selectedIndex) {
    final currentTrack = ref.watch(currentTrackProvider);
    final hasTrack = currentTrack != null;
    final paddingBottom = MediaQuery.viewPaddingOf(context).bottom;
    return Stack(

      children: [
        Scaffold(
          backgroundColor: AppTheme.background,
          body: widget.child,
          // La franja de la barra de gestos la pinta la propia barra de
          // navegacion, extendiendo su padding inferior con el inset del
          // sistema. Antes se resolvia con un `SafeArea` + una caja de color
          // detras, pero la sombra de la barra caia encima de esa caja y la
          // oscurecia: el tono quedaba parecido pero nunca igual. Con
          // edge-to-edge y navegacion por gestos Android ignora
          // `systemNavigationBarColor`, asi que esto tiene que resolverse aca.
          bottomNavigationBar: MeasuredBottomChrome(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const MiniPlayer(),
                _MobileNavBar(
                  selectedIndex: selectedIndex,
                  onItemTapped: _onItemTapped,
                  hasTrack: hasTrack,
                  bottomInset: paddingBottom,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          // Mismo alto medido que usan los avisos de `AppToast`, para que los
          // dos floten exactamente igual de alto sobre el chrome inferior.
          bottom: ref.watch(bottomChromeHeightProvider) + 12,
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
                                // Los `watch` van aquí y no dentro del builder
                                // del StreamBuilder: ahí corren fuera del build
                                // del Consumer, y con un provider que emite
                                // solo (las carpetas, Fase 8.E) Riverpod lee
                                // una suscripción ya cerrada.
                                final sort = ref.watch(librarySortProvider);
                                final activeContextId = ref.watch(playerStateProvider.select((s) => s.activeContextId));
                                final folders = ref.watch(foldersProvider).value ?? const <Folder>[];
                                return StreamBuilder<List<Playlist>>(
                                  stream: playlistDao.watchAllPlaylists(),
                                  builder: (ctx, snapshot) {
                                    // Ronda 4: mismo orden que Biblioteca
                                    // (fijadas primero, luego el criterio
                                    // elegido allí), en vez del orden crudo
                                    // de la tabla.
                                    final playlists = sortPlaylists(
                                      snapshot.data ?? const <Playlist>[],
                                      sort,
                                    );
                                    if (playlists.isEmpty) {
                                      return const Center(
                                        child: Text(
                                          'Sin playlists',
                                          style: TextStyle(color: AppTheme.secondary, fontSize: 12),
                                        ),
                                      );
                                    }

                                    // Fase 8.E: con la barra expandida, las
                                    // carpetas se despliegan en su sitio; con
                                    // la barra colapsada (solo portadas) la
                                    // lista sigue plana, como antes.
                                    final rows = <({Playlist? playlist, FolderEntry? folder, bool nested})>[];
                                    if (_isSidebarCollapsed) {
                                      for (final p in playlists) {
                                        rows.add((playlist: p, folder: null, nested: false));
                                      }
                                    } else {
                                      for (final e in buildLibraryEntries(playlists, folders)) {
                                        switch (e) {
                                          case PlaylistEntry(:final playlist):
                                            rows.add((playlist: playlist, folder: null, nested: false));
                                          case FolderEntry():
                                            rows.add((playlist: null, folder: e, nested: false));
                                            if (_expandedSidebarFolders.contains(e.folder.id)) {
                                              for (final p in e.playlists) {
                                                rows.add((playlist: p, folder: null, nested: true));
                                              }
                                            }
                                        }
                                      }
                                    }

                                    return ListView.builder(
                                      itemCount: rows.length,
                                      itemBuilder: (ctx, i) {
                                        final row = rows[i];
                                        final folderEntry = row.folder;
                                        if (folderEntry != null) {
                                          final folderId = folderEntry.folder.id;
                                          return _DesktopFolderItem(
                                            name: folderEntry.folder.name,
                                            subtitle: folderSubtitle(folderEntry.playlists.length),
                                            expanded: _expandedSidebarFolders.contains(folderId),
                                            isActivelyPlaying: folderEntry.playlists
                                                .any((p) => activeContextId == 'playlist_${p.id}'),
                                            onTap: () => setState(() {
                                              if (!_expandedSidebarFolders.remove(folderId)) {
                                                _expandedSidebarFolders.add(folderId);
                                              }
                                            }),
                                          );
                                        }
                                        final pl = row.playlist!;
                                        final isSelected = widget.location.endsWith('/playlist/${pl.id}') ||
                                            (pl.isLiked && widget.location.endsWith('/playlist/liked'));
                                        final isActivelyPlaying = activeContextId == 'playlist_${pl.id}';

                                        final item = _DesktopPlaylistItem(
                                          playlistId: pl.id,
                                          title: pl.title,
                                          // Ronda 4: sin la descripción, que
                                          // en la barra lateral era ruido.
                                          subtitle: pl.isPinned ? 'Fijada' : 'Playlist',
                                          coverUrl: pl.coverUrl ?? '',
                                          isLiked: pl.isLiked,
                                          isGenerated: pl.isGenerated,
                                          isSelected: isSelected,
                                          isActivelyPlaying: isActivelyPlaying,
                                          isCollapsed: _isSidebarCollapsed,
                                          onTap: () {
                                            ref.read(isLyricsOpenProvider.notifier).state = false;
                                            context.push('/playlist/${pl.isLiked ? 'liked' : pl.id}');
                                          },
                                        );
                                        return row.nested
                                            ? Padding(padding: const EdgeInsets.only(left: 14), child: item)
                                            : item;
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
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: UserAvatar(size: 28),
              ),
            ),
          // Fila propia con altura fija == altura de la barra (42) y
          // crossAxisAlignment.stretch: los botones (`_WindowCaptionButton`,
          // sin alto fijo propio) llenan todo el alto de la barra en vez de
          // quedar centrados con 2px muertos arriba/abajo -- ese margen
          // muerto es justo lo que dejaba el píxel exacto de la esquina
          // superior derecha de la pantalla sin click posible sobre el
          // botón de cerrar.
          SizedBox(
            height: 42,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        // Ronda 5: resaltado redondeado y separado del borde, como el resto de
        // botones de la app, en vez del bloque cuadrado de Windows. La zona de
        // clic sigue siendo toda la celda (46 px de ancho, alto completo).
        child: SizedBox(
          width: 46,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 36,
              height: 30,
              decoration: BoxDecoration(
                color: _isHovered ? widget.hoverColor : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
            widget.icon,
            size: 19,
            color: AppTheme.primary,
          ),
            ),
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

  /// Inset inferior del sistema (barra de gestos). Se suma al padding para que
  /// el fondo de la barra llegue hasta el borde real de la pantalla.
  final double bottomInset;

  const _MobileNavBar({
    required this.selectedIndex,
    required this.onItemTapped,
    this.hasTrack = false,
    this.bottomInset = 0,
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
        padding: EdgeInsets.only(top: 10, bottom: 10 + bottomInset),
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
/// Carpeta en la barra lateral de escritorio (Fase 8.E): se despliega en su
/// sitio al pulsarla, sin navegar a ninguna pantalla.
class _DesktopFolderItem extends StatefulWidget {
  final String name;
  final String subtitle;
  final bool expanded;
  final bool isActivelyPlaying;
  final VoidCallback onTap;

  const _DesktopFolderItem({
    required this.name,
    required this.subtitle,
    required this.expanded,
    required this.isActivelyPlaying,
    required this.onTap,
  });

  @override
  State<_DesktopFolderItem> createState() => _DesktopFolderItemState();
}

class _DesktopFolderItemState extends State<_DesktopFolderItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            color: _isHovered ? AppTheme.surfaceHover.withValues(alpha: 0.5) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            children: [
              const SizedBox(width: 48, height: 48, child: FolderCover(borderRadius: BorderRadius.all(Radius.circular(8)))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: const TextStyle(color: AppTheme.primary, fontSize: 14, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (widget.isActivelyPlaying && !widget.expanded)
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Icon(AppIcons.broken(SolarIcons.VolumeLoud), color: Colors.white, size: 18),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: AnimatedRotation(
                  turns: widget.expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopPlaylistItem extends StatefulWidget {
  final int? playlistId;
  final String title;
  final String subtitle;
  final String coverUrl;
  final bool isLiked;

  /// Playlist mantenida por la app ("On Repeat"): portada de color con su
  /// ícono, no la cuadrícula de portadas.
  final bool isGenerated;
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
    this.isGenerated = false,
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
    // Ronda 3 bis: sin `Tooltip`. El título de la playlist ya se lee en la
    // propia fila cuando la barra está expandida, así que el tooltip solo
    // repetía lo que había al lado; y con la barra colapsada la portada
    // identifica la playlist mejor que un texto flotante. (Los destinos de
    // navegación sí lo conservan: ahí, colapsados, solo se ve un icono.)
    return MouseRegion(
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
                      isGenerated: widget.isGenerated,
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
    );
  }
}
