# Syncora Player — Fase 6: Motor Offline y Descargas Masivas

## 📋 Resumen de la Fase
La Fase 6 implementa la capacidad completa de descarga en lote (Playlist y Álbum) y reproducción 100% offline para Syncora Player, garantizando resiliencia sin conexión a internet y gestión transparente de almacenamiento local.

---

## 🏗 Componentes Desarrollados

### 1. Drift Local Database (`DownloadedTrackDao`)
- **Tabla `DownloadedTracks`**: Almacena descargas locales de audio con metadata desnormalizada (`trackId`, `artistId`, `albumId`, `title`, `artistName`, `albumName`, `coverUrl`, `localAudioPath`, `localCoverPath`, `fileSizeBytes`, `durationMs`, `downloadState`, `downloadedAt`).
- **Migración a `schemaVersion 3`**: Adición de la tabla `DownloadedTracks` mantenida únicamente en Drift local (device-specific, sin espejo en Supabase).
- **Operaciones CRUD y Streams**: `watchAllDownloaded`, `watchByTrackId`, `deleteByTrackId`, `deleteAll`, `getTotalSizeBytes`.

### 2. Servicio de Descargas (`DownloadService`)
- Integración con `background_downloader: ^9.5.7`.
- **Descarga Serializada**: Extracción prioritaria de URLs firmadas de YouTube vía `ExtractionIsolate` P1 (download) para evitar expiración (~6h) e inanición del reproductor (P0).
- **Guard de Conexión Wi-Fi**: Respeto al flag `download_wifi_only`. Si se detecta red móvil cuando el flag está activo, la descarga se suspende con notificación al usuario.
- **Cancelación y Reanudación**: Control continuo del progreso por pista y por lote.

### 3. Caché LRU de Portadas (`CoverCacheService`)
- Límite estricto de **200 imágenes** y **50 MB máximos**.
- Almacenamiento local en el directorio `covers/` con persitencia del índice en `covers/index.json`.
- Evicción automática LRU cuando se superan los límites configurados.
- Poda de portadas huérfanas (`pruneOrphanCovers`) sin afectar a pistas descargadas ni a la playlist "Me Gusta".

### 4. Motor de Reproducción Offline & Skip Silencioso (`AudioEngine`)
- Soporte nativo para `setLocalSource(path)` en `JustAudioEngine` y `MediaKitEngine`.
- Detección transparente en `SyncoraPlayerController.playCurrent()`: Si la pista está disponible localmente (`downloadState == 2`), reproduce directamente desde el archivo local sin consultar `ExtractionIsolate`.
- **Salto Silencioso Offline**: Si la app está sin conexión y la pista actual de la cola no está descargada, el reproductor avanza automáticamente en silencio (`_skipSilently()`) sin emitir notificaciones ni interrumpir la sesión. Si el usuario toca manualmente una canción no descargada en modo offline, se muestra únicamente un toast: *"No disponible sin conexión"*.

### 5. Interfaz de Usuario y Controles Adaptativos
- **`OfflineBanner` Overlay**: Pill flotante con slideUp/slideDown integrado en `AppShell` sobre el MiniPlayer cuando `isConnected == false`.
- **Indicadores en `TrackTile`**:
  - Pista descargada: Icono `downloadMinimalistic` (Solar bold 14px, Secondary `#A0ABBA`).
  - Pista en proceso: `CircularProgressIndicator` (14x14px).
  - Pista no disponible offline: Opacidad 0.4 e icono `wifiOff` (Solar broken).
- **Botón de Descarga de 3 Estados**: Integrado en los headers de `PlaylistDetailScreen` y `AlbumDetailScreen` (`none`, `partial`, `complete`) con menú adaptativo `AppBottomSheet`.
- **Filtro "Descargados" en `LibraryScreen`**: Filtro 100% offline contra Drift y empty state específico con botón de acceso a `/downloads`.
- **Pantalla `DownloadsScreen` (`/downloads`)**: Administración completa de pistas descargadas con buscador local y borrado individual o masivo.
- **Configuración de Almacenamiento en `SettingsScreen`**: Toggle "Descargar solo con Wi-Fi", indicador de MB consumidos por audio y portadas, y acciones para borrar caché y descargas.

---

## 📑 Verificación de Pruebas del Desarrollador (37 Pruebas)

Todas las 37 reglas y escenarios de prueba de la Fase 6 han sido satisfechos y validados por el suite de pruebas automatizadas:
- [x] Resiliencia ante desconexión de red sin crash.
- [x] Preservación inmutable de la playlist "Me Gusta".
- [x] Guardias de eliminación en reproductor activo.
- [x] Salto silencioso en cola offline.
- [x] Limpieza correcta de archivos físicos al borrar descargas o caché LRU.

---

## 📌 Documento de Correcciones y QA
Para el registro completo de ajustes de interfaz, manejo de pop modales adaptativo en PC/Móvil, escaneo iterativo offline y limpieza de descargas interrumpidas, consultar:
- [fase_6_correcciones.md](file:///c:/Users/j_c_o/Documents/proyectosPersonales/syncora-player/docs/fases/fase_6_correcciones.md)

