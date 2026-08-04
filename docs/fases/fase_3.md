# Documentación de Fase 3: UI Core, Navegación y Pulido Adaptativo

## 📌 Resumen de Implementación
En la **Fase 3** se implementó la arquitectura completa de la interfaz de usuario de **Syncora Player**, proporcionando una experiencia visual premium, adaptativa y altamente reactiva tanto para escritorio (Windows) como para dispositivos móviles (Android).

---

## 🎨 Sistema de Diseño, Tokens y Pulido Visual
- **Paleta de Colores**:
  - Fondo (`AppTheme.background`): `#181C27`
  - Superficie (`AppTheme.surface`): `#1E2633` (Superficie sólida en navegación y tarjetas)
  - Superficie Hover / Inactiva (`AppTheme.surfaceHover`): `#252E3D`
  - Primario / Texto (`AppTheme.primary`): `#FFFFFF`
  - Secundario / Mutado (`AppTheme.secondary`): `#A0ABBA`
- **Tipografía**: Plus Jakarta Sans integrada globalmente en `AppTheme` con jerarquía visual pesada en títulos (`fontWeight: FontWeight.w900`, `letterSpacing: -0.8`).
- **Mitigación de Errores (Pitfall #9 - OOM Portadas)**: Uso estricto de `memCacheWidth: 300` (o `600` en reproductor fullscreen) en todas las instancias de `CachedNetworkImage`.
- **Efectos de Transición**: Deshabilitado el splash/ripple persistente (`splashColor: Colors.transparent`) en tarjetas de Android para transiciones limpias entre pantallas.
- **Fondos Limpios**: Removidos gradientes morados pesados en vistas de playlist y detalle de álbumes para mantener la sobriedad visual.

---

## 🗺️ Enrutamiento y Navegación (`GoRouter`)
Ubicación: `lib/core/navigation/app_router.dart`
Consumido mediante Riverpod (`appRouterProvider`) en `SyncoraApp`.

### Rutas Configuradas:
- `ShellRoute` (envueltas en `AppShell`):
  - `/` -> `HomeScreen` (con navegación directa desde "Tus me gusta" a `/playlist/liked`)
  - `/search` -> `SearchScreen`
  - `/library` -> `LibraryScreen`
  - `/playlist/:id` -> `PlaylistDetailScreen`
  - `/album/:id` -> `AlbumDetailScreen`
  - `/artist/:id` -> `ArtistDetailScreen`
  - `/settings` -> `SettingsScreen`
- Standalone Route:
  - `/player` -> `PlayerFullscreenScreen` (sin shell de navegación)

---

## 📱 Layout Adaptativo (`AppShell`) y Controles de Ventana
Ubicación: `lib/core/layout/app_shell.dart`
Determina la interfaz de forma adaptativa según el ancho de pantalla y orientación:

1. **Escritorio (Windows)**:
   - **Barra de Ventana Custom**: Integración con `window_manager` y `TitleBarStyle.hidden` para una barra superior frameless estilo Spotify, con área de arrastre (`DragToMoveArea`) y botones personalizados (minimizar, maximizar/restaurar, cerrar).
   - **Sidebar Lateral Resizable**: Panel lateral redimensionable mediante arrastre horizontal (rango `180px` a `400px`) y botón de minimizar a 80px con animación fluida mediante `ClipRect`.
   - **Comportamiento Landscape Móvil**: Detección de dispositivos móviles físicos en orientación horizontal (`shortestSide < 600`) para ocultar automáticamente la sección de playlists del sidebar y optimizar el espacio vertical.
2. **Móvil (Android / pantallas < 768px)**:
   - `_MobileNavBar` centrado con íconos de `LucideIcons`.
   - `MiniPlayer` flotante justo encima de la barra de navegación.
   - Fondo dinámico detrás de las esquinas superiores curvadas de la barra de navegación, visible únicamente cuando hay un reproductor activo.

---

## 🎵 Componentes del Reproductor

### 1. MiniPlayer (`lib/features/player/widgets/mini_player.dart`)
- Reactivo a `currentTrackProvider` e `isPlayingProvider`.
- Ocultación automática cuando no hay canción en cola.
- Portada 48x48 con `Hero` animation hacia el reproductor fullscreen.
- Controles multimedia (Play/Pause, Me gusta) y reproducción continua.

### 2. Fullscreen Player (`lib/features/player/screens/player_fullscreen_screen.dart`)
- Extracción dinámica de color dominante (`palette_generator`) para el gradiente de fondo.
- Waveform procedural interactivo (36 barras animadas generadas por el hash de la canción).
- Gestos: Deslizar hacia abajo para minimizar.
- Controles: Aleatorio (Shuffle), Anterior, Play/Pause con White Glow, Siguiente, Modo de Repetición (off, all, one), Me Gusta (Heart), Botón de Letras (LRCLib stub) y Hoja de Cola (`AppBottomSheet`).

---

## ⚙️ Configuración (`SettingsScreen`)
Ubicación: `lib/features/settings/screens/settings_screen.dart`
- Conexión 100% real de la opción **Skip Silence** (`Saltar silencios`) con `SyncoraPlayerController.setSkipSilence(bool)`.

---

## 🧪 Verificación y Estado
- **`flutter analyze`**: 0 errores / `No issues found!`.
- **Integridad de Código**: Verificado compilación en Windows y Android.
