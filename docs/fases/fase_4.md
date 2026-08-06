# Syncora Player — Fase 4: Datos y Metadatos

## 📋 Resumen de la Fase

La **Fase 4** dota a Syncora Player de una capa de datos sólida, persistente y desacoplada, integrando la API de Deezer para metadatos musicales, una base de datos local SQLite reactiva a través de **Drift**, soporte completo para importación y exportación de listas de reproducción (Formatos TuneMyMusic, CSV y TXT) y letras de canciones sincronizadas mediante la API de **LRCLib**.

---

## 🏗️ Arquitectura Implementada

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
│   │   ├── import_export/
│   │   │   └── playlist_import_export_service.dart # Parseador CSV/TXT + Proceso con delay 200ms
│   │   └── screens/
│   │       ├── library_screen.dart          # Vista de Biblioteca real (Stream Drift + Importación)
│   │       ├── playlist_detail_screen.dart  # Vista Detalle Playlist (Stream Drift + Exportación CSV)
│   │       └── album_detail_screen.dart     # Vista Detalle Álbum (Guardado en DB + Deezer)
│   ├── search/
│   │   ├── search_provider.dart     # SearchNotifier con Debouncer (500ms) y Riverpod Notifier
│   │   └── screens/
│   │       ├── search_screen.dart        # Búsqueda real con Filtros, Skeleton y Retry
│   │       └── artist_detail_screen.dart # Vista Detalle Artista (Top Tracks + Álbumes)
│   └── player/
│       ├── screens/
│       │   └── player_fullscreen_screen.dart # Integración de Me Gusta persistente y Letras
│       └── widgets/
│           └── lyrics_sheet.dart    # Modal de Letras Karaoke Sincronizadas (Highlight en tiempo real)
```

---

## 🛡️ Prevención de Pitfalls Cumplida

1. **Pitfall #3 (Single Source of Truth en DB desnormalizada)**:
   - Se duplicaron los campos básicos (`title`, `artistName`, `albumName`, `coverUrl`, `durationMs`) en `PlaylistTracks` para renderizado instantáneo offline sin requerir joins complejos ni queries de red adicionales.

2. **Pitfall #4 & #22 (Rate Limit Deezer: <50 req/5s)**:
   - Se implementó un `RateLimiter` con algoritmo Token Bucket / Ventana Deslizante restringido a máximo 45 peticiones por cada 5 segundos.
   - Búsqueda en UI cuenta con `Debouncer` de 500ms.
   - Importación masiva de playlists introduce un retardo estricto de `200ms` entre peticiones secuenciales.

3. **Pitfall #5 (Drift Background Isolate para Native)**:
   - Se configuró `NativeDatabase.createInBackground(file)` para plataformas nativas (Windows/Android), asegurando I/O no bloqueante en el thread de UI.

4. **Pitfall #6 (Web Bypass para Drift)**:
   - Para entorno `kIsWeb`, la base de datos conmuta a `NativeDatabase.memory()`, evitando cierres inesperados por bibliotecas nativas de SQLite.

5. **Pitfall #9 (Imágenes con Cache y memCacheWidth)**:
   - `CachedNetworkImage` configurado con `memCacheWidth: 300` (o 600 en encabezados de artista) en todas las portadas para controlar uso de memoria RAM.

---

## 🛠️ Correcciones de Compilación y Calidad Aplicadas

1. **Resolución de Error de Compilación Windows (`atlstr.h`)**:
   - Se identificó que la biblioteca no utilizada `flutter_secure_storage` arrastraba `flutter_secure_storage_windows: 4.1.0` que requería los encabezados C++ de Microsoft ATL (`#include <atlstr.h>`).
   - Se eliminó `flutter_secure_storage` de `pubspec.yaml`, eliminando la dependencia nativa problemática y logrando la compilación limpia de `syncora_player.exe`.

2. **Resolución de Error de Compilación Android (`compileSdk = 36`)**:
   - Plugins como `file_picker` tenían `compileSdkVersion 34` hardcodeado internamente en su `build.gradle`, lo cual chocaba con el requisito de Android SDK 36 de Flutter.
   - En `android/build.gradle.kts`, se configuró un bloque `subprojects` con `overrideCompileSdk()` con evaluación condicional (`if (state.executed) ... else afterEvaluate`), forzando `compileSdk = 36` en todas las subbibliotecas Android.

3. **Optimizaciones de Código (Auto-Auditoría con Agente)**:
   - **Búsqueda**: Se agregó verificación de guard de condiciones de carrera (`if (state.query.trim() != query) return;`) para evitar que consultas rápidas subsiguientes sobrescriban el estado más reciente.
   - **Cache LRU**: Corrección en `DeezerApi` para actualizar la posición LRU en lecturas exitosas.
   - **LRCLib**: Prevenida la memorización de respuestas fallidas/nulas de red.
   - **Atomicidad Drift**: Métodos con secuencia lectura-escritura en `PlaylistDao` y `SavedAlbumDao` protegidos mediante transacciones atómicas `transaction(...)`.

---

## 🧪 Matriz de Pruebas Automatizadas

1. `test/data/deezer_api_test.dart`:
   - `RateLimiter` respeta límites de frecuencia.
   - Filtro de podcasts excluye resultados `type == 'podcast'` y canciones `< 60s`.

2. `test/data/playlist_dao_test.dart`:
   - Operaciones CRUD de playlists en base de datos `NativeDatabase.memory()`.
   - Inserción y consulta en orden exacto por `orderIndex`.
   - Eliminación de canciones y toggle automático de playlist "Tus me gusta".

3. `test/data/import_export_test.dart`:
   - Parseo de CSV estándar de 5 canciones.
   - Parseo de formato TuneMyMusic con columna `ISRC`.
   - Parseo de texto plano `"Artista - Título"`.
   - Exportación a formato CSV de 4 columnas (`title,artist,album,duration_ms`).

---

## 🏁 Estado Actual del Proyecto y Verificación

- `flutter analyze`: **0 errores, 0 advertencias (0 issues)**.
- `flutter test`: **36/36 pruebas pasadas con éxito**.
- `flutter build windows --debug`: **Exitoso** (`build\windows\x64\runner\Debug\syncora_player.exe`).
- `flutter build apk --debug`: **Exitoso** (`build\app\outputs\flutter-apk\app-debug.apk`).

---

## 📋 Lista de Pruebas Manuales Pendientes (Paso previo al Commit)

1. **Búsqueda real**: Buscar "Coldplay" → comprobar metadatos reales de Deezer → reproducir canción.
2. **Persistencia local**: Crear playlist → agregar canciones → cerrar y reabrir la app (verificar persistencia en Drift).
3. **Importación y Exportación**: Importar un CSV de ejemplo de TuneMyMusic → exportar playlist a CSV.
4. **Letras Sincronizadas**: Reproducir canción conocida ("Bohemian Rhapsody") → abrir sheet de letras → verificar resaltado karaoke en tiempo real.

---

## 🎨 Migración del Sistema de Íconos (Lucide Icons -> Solar Icons)

1. **Motivación y Diagnóstico**:
   - Se migró la biblioteca de íconos base de Lucide Icons a **Solar Icons**.
   - En el paquete inicial `solar_icons: ^0.1.0` se detectó un bug de empaquetado de mapa de caracteres Unicode rotos en fuentes TTF nativas (mostraba cuadrados/círculos en blanco).
   - Se reemplazó exitosamente por `flutty_solar_icons: ^1.0.4` que empaqueta correctamente todas las variantes de fuentes TTF (`SolarBroken`, `SolarBold`, `SolarLinear`, `SolarOutline`, `SolarBoldDuotonePrimary`, `SolarLineDuotonePrimary`).

2. **Arquitectura del Helper `AppIcons`**:
   - Se creó `lib/core/theme/app_icons.dart` con la abstracción `AppIcons`:
     - `AppIcons.broken(SolarIcons.xxx)`: Aplica el estilo `SolarBroken` (trazo 1.5px punteado por defecto).
     - `AppIcons.bold(SolarIcons.xxx)`: Aplica el estilo `SolarBold` (relleno sólido para elementos seleccionados/activos).
   - Mapeo exacto de nombres de constantes del paquete (`HomeN2`, `Magnifer`, `AddCircle`, `PlaylistMinimalisticN2`, `WiFiRouter`, etc.).

3. **Verificación**:
   - `flutter analyze`: **0 errores, 0 advertencias**.
   - `flutter test`: **26/26 pruebas unitarias y de widgets pasadas**.

