# Documentación de Fase 3: UI Core y Navegación

## 📌 Resumen de Implementación
En la **Fase 3** se implementó la arquitectura completa de la interfaz de usuario de **Syncora Player**, proporcionando una experiencia visual premium, adaptativa y altamente reactiva tanto para escritorios (Windows) como para dispositivos móviles (Android).

---

## 🎨 Sistema de Diseño y Tokens
- **Paleta de Colores**:
  - Fondo (`AppTheme.background`): `#181C27`
  - Superficie (`AppTheme.surface`): `#1E2633` (Superficie sólida sin glassmorphism en áreas de alto contacto)
  - Superficie Hover / Inactiva (`AppTheme.surfaceHover`): `#2A3447`
  - Primario / Texto (`AppTheme.primary`): `#FFFFFF`
  - Secundario / Mutado (`AppTheme.secondary`): `#A0AEC0`
- **Tipografía**: Plus Jakarta Sans integrada globalmente en `AppTheme`.
- **Mitigación de Errores (Pitfall #9 - OOM Portadas)**: Uso estricto de `memCacheWidth: 300` (o `600` en reproductor fullscreen) en todas las instancias de `CachedNetworkImage`.

---

## 🗺️ Enrutamiento y Navegación (`GoRouter`)
Ubicación: `lib/core/navigation/app_router.dart`
Consumido mediante Riverpod (`appRouterProvider`) en `SyncoraApp`.

### Rutas Configuradas:
- `ShellRoute` (envueltas en `AppShell`):
  - `/` -> `HomeScreen`
  - `/search` -> `SearchScreen`
  - `/library` -> `LibraryScreen`
  - `/playlist/:id` -> `PlaylistDetailScreen`
  - `/album/:id` -> `AlbumDetailScreen`
  - `/artist/:id` -> `ArtistDetailScreen`
  - `/settings` -> `SettingsScreen`
- Standalone Route:
  - `/player` -> `PlayerFullscreenScreen` (sin shell de navegación)

---

## 📱 Layout Adaptativo (`AppShell`)
Ubicación: `lib/core/layout/app_shell.dart`
Determina la interfaz de forma adaptativa según el ancho de pantalla (`MediaQuery.of(context).size.width >= 768`):

1. **Móvil (Android / pantallas < 768px)**:
   - `NavigationBar` inferior con 3 destinos (Inicio, Buscar, Biblioteca).
   - `MiniPlayer` flotante justo encima de la barra de navegación.
2. **Escritorio (Windows / pantallas >= 768px)**:
   - Sidebar lateral izquierdo con Logo, enlaces directos (Inicio, Buscar, Biblioteca) y acceso a Configuración en la parte inferior.
   - Área central de contenido dinámico.
   - `MiniPlayer` continuo de ancho completo en la parte inferior.

---

## 🎵 Componentes del Reproductor

### 1. MiniPlayer (`lib/features/player/widgets/mini_player.dart`)
- Reactivo a `currentTrackProvider` e `isPlayingProvider`.
- Ocultación automática cuando no hay canción en cola.
- Portada 40x40 (`memCacheWidth: 300`) con `Hero` animation hacia el reproductor fullscreen.
- Controles multimedia (Play/Pause, Siguiente) y barra de volumen + acceso a cola en escritorio.

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

## 🧪 Verificación y Pruebas
- **`flutter analyze`**: 0 errores.
- **`flutter test`**: 28 pruebas pasadas de 28 ejecutadas.
- **`flutter build windows --debug`**: Binario `syncora_player.exe` compilado exitosamente.

---

## 📋 Lista de Comprobación QA Manual
Por favor ejecuta las siguientes pruebas en tu entorno local:

1. **Escritorio (Windows)**:
   ```bash
   flutter run -d windows
   ```
   - Verifica el layout con Sidebar lateral izquierdo y la barra del reproductor continua en la parte inferior.
   - Haz clic en las distintas secciones (Inicio, Buscar, Biblioteca, Ajustes).
   - Toca una canción para abrir la mini barra inferior y haz clic en la portada para abrir el reproductor Fullscreen.

2. **Móvil (Android)**:
   ```bash
   flutter run -d android
   ```
   - Verifica que aparezca la `NavigationBar` inferior y el `MiniPlayer` flotando arriba de ella.
   - Desliza hacia abajo en el reproductor Fullscreen para minimizarlo.

3. **Skip Silence**:
   - Ve a `Configuración` -> cambia el interruptor de `Saltar silencios` y confirma que el estado se refleje correctamente.
