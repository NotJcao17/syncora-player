# Syncora Player — Fase 4: Datos y Metadatos

## 📋 Resumen de la Fase

La **Fase 4** dota a Syncora Player de la capa de datos local y remota, integrando la API de Deezer para metadatos musicales, la base de datos local SQLite reactiva mediante **Drift**, el sistema de importación/exportación de listas de reproducción (CSV/TXT) y las letras sincronizadas vía **LRCLib**.

---

## 🏗️ Estructura de Datos y APIs Implementadas

```
lib/
├── data/
│   ├── apis/
│   │   ├── deezer_api.dart          # Cliente Deezer REST + RateLimiter (<45 req/5s) + Cache LRU
│   │   ├── deezer_provider.dart     # Riverpod Provider de DeezerApi
│   │   ├── lrclib_api.dart          # Cliente LRCLib REST + LrcLine Parser + In-memory cache
│   │   └── lrclib_provider.dart     # Riverpod Provider de LRCLibApi
│   ├── local_db/
│   │   ├── syncora_database.dart    # Tablas Drift: Playlists, PlaylistTracks, SavedAlbums, History
│   │   ├── syncora_database.g.dart  # Código generado por build_runner
│   │   ├── database_provider.dart   # Providers de DB y DAOs
│   │   └── daos/
│   │       ├── playlist_dao.dart           # Operaciones CRUD para Playlists y Liked Songs
│   │       ├── saved_album_dao.dart        # Operaciones para Álbumes Guardados
│   │       └── listening_history_dao.dart  # Operaciones para Historial de Reproducción
│   └── models/
│       └── deezer/                  # DTOs: DeezerTrack, DeezerArtist, DeezerAlbum, DeezerSearchResult
├── features/
│   ├── library/
│   │   └── import_export/
│   │       └── playlist_import_export_service.dart # Parseador CSV/TXT
│   ├── search/
│   │   └── search_provider.dart     # SearchNotifier con Debouncer (500ms)
│   └── player/
│       ├── session/
│       │   └── player_session_storage.dart # Persistencia de sesión de reproductor (JSON)
│       └── audio_engine/            # Abstracción AudioEngine (JustAudioEngine / MediaKitEngine)
```

---

## 🛡️ Principios Arquitectónicos y Tablas Base

1. **Tabla `PlaylistTracks` (Desnormalizada para Acceso Offline)**:
   - Se almacenan `title`, `artistName`, `albumName`, `coverUrl`, `durationMs` y `genre` dentro de la tabla de canciones de playlist para permitir renderizado instantáneo y reproducción sin consultar red.

2. **Esquema de Tablas Drift (SQLite)**:
   - **`Playlists`**: `id`, `title`, `description`, `coverUrl`, `isLiked`, `isPinned`, `orderIndex`, `createdAt`, `updatedAt`.
   - **`PlaylistTracks`**: `id`, `playlistId`, `trackId` (Deezer), `artistId`, `albumId`, `title`, `artistName`, `albumName`, `coverUrl`, `durationMs`, `genre`, `orderIndex`, `addedAt`.
   - **`SavedAlbums`**: `id`, `albumId`, `title`, `artistName`, `coverUrl`, `addedAt`.
   - **`ListeningHistory`**: `id`, `trackId`, `artistId`, `albumId`, `genre`, `listenedAt`, `durationListenedMs` *(Base para estadísticas Wrapped)*.

3. **Rate Limiting y Control de Red**:
   - `RateLimiter` restrictivo a $< 45$ req / 5s para respetar límites de la API de Deezer.
   - Búsqueda en UI con `Debouncer` de 500ms.
   - Retardo de 200ms por item en importaciones masivas para evitar saturación de red.

---

## 🏁 Estado de Verificación

- `dart analyze`: **0 errores, 0 advertencias (0 issues)**.
- `flutter test`: **45/45 pruebas pasadas con éxito (100%)**.
- `flutter build windows --debug`: **Exitoso**.
- `flutter build apk --debug`: **Exitoso**.
- Ajustes técnicos y resiliencia: [`fase_4_correcciones.md`](file:///c:/Users/j_c_o/Documents/proyectosPersonales/syncora-player/docs/fases/fase_4_correcciones.md).
