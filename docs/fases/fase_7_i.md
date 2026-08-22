# Syncora Player — Fase 7.I: Modo local / sin cuenta

## Resumen

Modo local disponible desde el lanzamiento (D-23): el usuario puede usar la app sin crear cuenta.
La biblioteca vive solo en Drift local, sin sincronización entre dispositivos, sin respaldo en la
nube y sin funciones de IA. El refactor central (H-5, D-24) cambia el gating de edición de
`isConnected` a `canEdit = isLocalMode || isConnected` -- sin nube que mantener consistente en modo
local, la restricción Online-First no aplica.

## Componentes

### Infraestructura nueva

- **`lib/features/auth/services/local_mode_storage.dart`** -- `LocalModeStorage` (interfaz
  inyectable, mismo patrón que `AiKeyStorage` de 7.E.8) + `SecureLocalModeStorage`. Reusa
  `flutter_secure_storage` (ya dependencia del proyecto) en vez de agregar `shared_preferences`
  (que el proyecto no tiene) solo para dos strings. Guarda el flag de modo local y una semilla de
  avatar local (16 bytes aleatorios en hex, sin agregar el paquete `uuid` -- solo llega
  transitivamente hoy).
- **`lib/features/auth/local_mode_provider.dart`** -- `localModeProvider` (`Notifier<bool>` con
  `enable()`/`disable()` que persisten), `localAvatarSeedProvider`, y dos funciones puras
  extraídas específicamente para poder testearlas sin Riverpod: `computeCanEdit({isLocalMode,
  isConnected})` acá, y `computeAuthRedirect({hasUser, isLocalMode, location})` en
  `app_router.dart`. Ambas extracciones existen porque el código que envuelven (un `Provider`
  derivado de un `StreamProvider`, y el `redirect:` de GoRouter) es awkward o imposible de testear
  directamente -- el `redirect` real se salta por completo en entorno de test (`isTestEnv`), así
  que sin la extracción esa lógica nunca se había ejercitado en ningún test del proyecto.
- **`lib/main.dart`** -- precarga `SecureLocalModeStorage().getIsLocalMode()` ANTES de `runApp` e
  inyecta el valor vía `ProviderScope(overrides: [localModeProvider.overrideWith(() =>
  LocalModeNotifier(initialLocalMode))])`. Necesario porque el `redirect` de GoRouter es síncrono
  y no puede esperar un `FutureProvider`.

### Router y auth

- **`lib/core/navigation/app_router.dart`** (7.I.2) -- el gate pasa de `currentUser == null` a
  `currentUser == null && !isLocalMode`. `appRouterProvider` hace `ref.watch(localModeProvider)`
  (no `read`) para que tocar "Usar sin cuenta" reconstruya el router y el redirect se reevalúe de
  inmediato, mismo mecanismo que ya usaba `currentUser`.
- **`lib/features/auth/screens/auth_screen.dart`** (7.I.3/7.I.10) -- botón "Usar sin cuenta"
  (`_useWithoutAccount`), con la explicación honesta que pide D-23 (sin sync, sin respaldo, sin
  IA) visible junto al botón, no como letra chica. Migración local -> cuenta (D-25): cuando
  `onAuthStateChange` emite una sesión nueva y el usuario estaba en modo local en ese momento,
  dispara `_migrateLocalLibrary()` (overlay de carga a pantalla completa) antes de navegar, y
  limpia el flag de modo local en un `finally` pase lo que pase.
- **`lib/features/library/import_export/playlist_import_export_service.dart`** --
  `migrateLocalPlaylistsToAccount({dao, supabaseRepo})`: recorre las playlists locales sin
  `remoteId`, sube cada una (playlist + tracks, con los datos ya resueltos localmente, sin volver
  a golpear Deezer) y recién entonces marca `remoteId`. Cada playlist en su propio `try/catch` --
  un fallo no aborta las demás, y como solo procesa playlists SIN `remoteId`, un reintento
  posterior es idempotente por construcción (7.I.16).

### UI: `canEdit` y ocultar lo que no aplica

- **`library_screen.dart`** (7.I.7/7.I.8) -- crear/editar/eliminar playlist pasan de `isConnected`
  a `canEdit`. Se OCULTAN (no deshabilitan) en modo local: las 2 entradas de IA, "Hacer
  pública/privada", "Copiar enlace", y el ícono de sincronización manual. El `initState` salta la
  sync automática si `isLocalMode`.
- **`album_detail_screen.dart`** -- oculta el botón de sync manual, saltea la sync en
  pull-to-refresh. Guardar/quitar álbumes ya funcionaba 100% local (sin gating de `isConnected`
  previo), no necesitó cambios ahí.
- **`playlist_detail_screen.dart`** -- **sin cambios**: ya no usa `isConnectedProvider` en ningún
  lado (usa `_executeRemoteMutation`, con guardas por `remoteId != null`), y las llamadas a
  `syncPlaylistDetail` ya estaban gateadas por `remoteId != null` -- en modo local los playlists
  nunca tienen `remoteId`, así que esas llamadas ya eran no-op sin tocar nada.
- **`app_shell.dart`** -- el popup de perfil de escritorio, antes gateado por `if (user != null)`
  (sin forma de llegar a Configuración desde escritorio en modo local), ahora también se muestra
  con `isLocalMode == true`; "Cerrar sesión" se oculta dentro del popup en ese caso.
- **`settings_screen.dart`** (7.I.9) -- "MI CUENTA" se reemplaza por un bloque "MODO LOCAL"
  (`_LocalModeSection`): explica la contrapartida, botón "Crear cuenta y subir mi biblioteca"
  (navega a `/auth`), menciona el CSV de cada playlist como respaldo (7.I.11 -- el botón real ya
  existía en `playlist_detail_screen.dart` desde antes de esta fase, esto solo le da visibilidad).
  La sección de IA (BYOK) se oculta en modo local.
- **Avatar en modo local (7.I.4)** -- `avatar_selector_sheet.dart`: el slot "tu avatar único" caía
  siempre a un `'default'` genérico cuando no había `userId`; ahora usa `currentSeed` (la semilla
  local real) si se pasa. `settings_screen.dart`/`home_screen.dart`/`app_shell.dart`: usan
  `localAvatarSeedProvider` en vez de `profiles.avatar_seed` cuando `isLocalMode`.

## Decisión de alcance: 7.I.5 (sync no-op) sin tocar `SyncService`

El plan sugería "cortar en `SyncService`" para que toda sincronización sea no-op en modo local.
Se evaluó y se descartó: los métodos públicos de `SyncService` (`syncLibrary`, `syncPlaylistDetail`,
`syncListeningHistory`) no tienen forma barata de distinguir "modo local" de "entorno de test" sin
inyectar el estado -- agregar `if (_isTestEnv) return` a esos métodos rompía los tests existentes
de `sync_service_test.dart`, que los llaman directamente con repos mockeados y esperan que
ejecuten su lógica real, independientemente de cualquier sesión de Supabase. Como los repositorios
YA tienen guardas de nulo (H-5) que hacen esas llamadas inofensivas y sin tráfico de red real
incluso sin este cambio, la solución elegida fue cortar en los **puntos de disparo de la UI**
(`library_screen.dart` initState + pull-to-refresh, `album_detail_screen.dart` botón de sync +
pull-to-refresh) en vez de en el servicio -- menos invasivo, no rompe tests, y cubre exactamente
los casos donde el usuario vería un control de sync que no hace nada.

## Revisión independiente

Fase con la mayor superficie de la Fase 7 hasta ahora (toca `auth`, routing, y gating de edición
en ~6 pantallas). Revisión hecha por un subagente **Opus** (effort alto, excepción pre-aprobada
explícitamente por el plan solo para 7.I) aparte del que implementó, sobre el diff completo sin
commitear. Encontró 3 hallazgos P0 (pérdida de datos real) y 3 P1, los 6 corregidos antes de
cerrar la fase:

1. **[P0, corregido]** La migración solo subía playlists -- el primer `syncLibrary` tras crear la
   cuenta **podaba (borraba) todos los álbumes guardados locales** que no existieran en el
   (todavía vacío) remoto, porque `_syncSavedAlbumsInternal` (`sync_service.dart`) elimina
   localmente cualquier álbum ausente del servidor. Corregido con
   `PlaylistImportExportService.migrateLocalSavedAlbumsToAccount`, llamado junto con la migración
   de playlists en `_migrateLocalLibrary` -- usa `SupabaseAlbumRepository.saveAlbum`
   (`upsert(onConflict: 'user_id,album_id')`), así que no hace falta rastrear "ya migrado" ni
   arriesgar duplicados en un reintento.
2. **[P0, corregido]** `migrateLocalPlaylistsToAccount` creaba la "Tus me gusta" local con
   `createPlaylist(isLiked: true)` a ciegas -- si el usuario local iniciaba sesión en una cuenta
   **existente** (no un registro nuevo) que ya tenía su propia liked remota, quedaban dos, y el
   dedup de `_syncPlaylistsAndTracks` conserva una arbitrariamente y borra la otra en el servidor
   (podía borrar justo la recién migrada con los likes locales). Corregido usando
   `supabaseRepo.getOrCreateLikedPlaylist()` para el caso `isLiked`, que reusa la liked remota
   existente si ya hay una.
3. **[P0, corregido]** Modo local "pegado" tras un crash a mitad de `_migrateLocalLibrary`: el
   `finally` que limpia el flag nunca llegaba a correr, dejando el flag persistido en `true` con
   una sesión real ya establecida. Sin salida real: "Crear cuenta y subir mi biblioteca" en
   Configuración navega a `/auth`, pero `computeAuthRedirect` rebota `/auth` -> `/` porque
   `hasUser == true`, y "Cerrar sesión" se oculta por estar en (aparente) modo local. Corregido en
   `main.dart`: si el flag persistido es `true` pero ya hay una sesión real de Supabase al
   arrancar, se descarta el flag obsoleto antes de inyectarlo (autocorrección al siguiente
   arranque de la app). Las playlists que hubieran quedado a mitad de subir no se pierden --
   quedan como playlists local-only normales (estado ya soportado, H-5) -- pero no se reintenta su
   migración automáticamente después de este punto; aceptado como límite conocido de un camino que
   solo se alcanza con un crash real a mitad de la migración.
4. **[P1, corregido]** Reentrancy: `_migrateLocalLibrary` seteaba `_isMigrating` pero no lo
   consultaba -- dos eventos de `onAuthStateChange` con sesión casi seguidos podían lanzar dos
   migraciones concurrentes y subir todo duplicado. Corregido con un guard `if (!mounted ||
   _isMigrating) return;` al inicio.
5. **[P1, corregido]** Si `addTracksToPlaylist` fallaba después de que `createPlaylist` ya había
   creado la playlist remota (pero antes de marcar `remoteId` local), un reintento repetía
   `createPlaylist` a ciegas y duplicaba la playlist en el servidor. Corregido: antes de crear,
   `migrateLocalPlaylistsToAccount` busca primero por título entre las playlists remotas ya
   existentes del usuario (una sola consulta cacheada) y reusa el id si la encuentra, en vez de
   crear siempre.
6. **[P1, corregido]** El gating de IA ocultaba las 2 entradas de `library_screen.dart`, pero
   dejaba visibles "Crear cola con IA"/"Mejorar esta cola" (`queue_view.dart`) y "Buscar por letra"
   (`search_screen.dart`) -- sin JWT esas llamadas habrían ido con la llave anónima y fallado con
   un 401 crudo. Corregidas las 4 entradas restantes con el mismo patrón `if (!isLocalMode)`.
7. **[P2, corregido, sin impacto funcional]** `avatar_selector_sheet.dart`: el callback
   `onAvatarSelected` no se `await`eaba (tipo `ValueChanged<String>`, síncrono) -- un fallo del
   guardado local en modo local quedaba como excepción de `Future` sin capturar. Corregido
   cambiando el tipo a `Future<void> Function(String)?` y agregando el `await`.

Sin hallazgos en: el gate del router (`computeAuthRedirect`, sin huecos ni loops -- el problema
era el estado "pegado" del punto 3, no el redirect en sí), `canEdit` en las rutas de escritura
Drift-only de `library_screen.dart` (no dependen de nada que solo exista con sesión), ni la
carrera de `main.dart` al precargar `initialLocalMode` (el `overrides` del `ProviderScope` raíz se
aplica antes de que nada lo lea).

## Verificación de pruebas

- `flutter analyze`: limpio (28 lints `info` preexistentes, mismo baseline que el resto de la
  Fase 7).
- `flutter test`: **332 tests, 0 fallos** (suite completa, una sola corrida antes de comitear --
  313 del baseline + 19 nuevos).
- Tests nuevos: `test/core/navigation/auth_redirect_test.dart` (`computeAuthRedirect`, 7.I.12),
  `test/features/auth/local_mode_provider_test.dart` (`LocalModeNotifier`/persistencia, 7.I.15;
  `computeCanEdit`, 7.I.14), `test/features/library/playlist_migration_test.dart`
  (`migrateLocalPlaylistsToAccount`, 7.I.16 -- reintento sin duplicar, dedup de "Tus me gusta"
  contra una cuenta existente, reutilización por título tras un fallo parcial; y
  `migrateLocalSavedAlbumsToAccount`).
- **7.I.13** ("ninguna operación de biblioteca intenta llamar a Supabase en modo local") no tiene
  un test dedicado nuevo: la garantía real viene de (a) los guardas de nulo preexistentes en los
  repositorios (H-5, no tocados en esta fase) y (b) los puntos de disparo de UI ahora gateados por
  `isLocalMode` explícitamente (ver decisión de arriba) -- verificable por inspección del diff, no
  se armó un harness de widget test nuevo para `LibraryScreen` (no existía ninguno antes de esta
  fase) dado el costo de levantarlo contra el alcance ya grande de 7.I.

## Pendiente

Ninguno bloqueante. Sigue 7.G (Estadísticas y Wrapped) -- último punto del orden no negociable de
la Fase 7 (7.I antes que 7.G, ya cumplido).
