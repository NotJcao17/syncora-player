# Syncora Player — Fase 5: Nube, Auth y Sincronización

Este documento registra los logros, arquitectura y decisiones de implementación aplicadas en la **Fase 5**.

---

## 1. Migraciones de Base de Datos en Supabase (PostgreSQL)

Se crearon y aplicaron las siguientes migraciones mediante `supabase db push --db-url "$env:SUPABASE_DB_URL"`:

1. **`20250001000000_initial_schema.sql`**:
   - `public.profiles` (`id` FK a `auth.users`, `avatar_seed`, `download_wifi_only`, `created_at`).
   - `public.playlists` (`id`, `user_id`, `title`, `description`, `cover_url`, `is_public`, `is_liked`, `is_pinned`, `order_index`, `created_at`, `updated_at`).
   - `public.playlist_tracks` (`id`, `playlist_id`, `user_id`, `is_public`, `track_id`, `artist_id`, `album_id`, `title`, `artist_name`, `album_name`, `cover_url`, `duration_ms`, `genre`, `order_index`, `added_at`).
   - `public.saved_albums` (`id`, `user_id`, `album_id`, `title`, `artist_name`, `cover_url`, `added_at`, UNIQUE(`user_id`, `album_id`)).
   - `public.listening_history` (`id`, `user_id`, `track_id`, `artist_id`, `album_id`, `genre`, `listened_at`, `duration_listened_ms`).
   - `public.yt_matches` (`track_id` PK, `youtube_video_id`, `corrected_at`).

2. **`20250001000001_is_public_trigger.sql`**:
   - Trigger `playlist_tracks_sync_is_public`: actualiza automáticamente `is_public` en `playlist_tracks` cuando cambia la visibilidad de una playlist.
   - Trigger `playlist_track_set_defaults`: asigna automáticamente el valor de `is_public` correspondiente al insertar una pista nueva.

3. **`20250001000002_rls_policies.sql`**:
   - Habilitado Row Level Security (RLS) en todas las tablas.
   - Políticas para acceso por propietario (`auth.uid() = user_id`) y lectura pública para recursos con `is_public = true`.

4. **`20250001000003_auto_create_profile.sql`**:
   - Trigger `on_auth_user_created` que crea el perfil en `public.profiles` con `avatar_seed = user.id`.

---

## 2. Autenticación (Google OAuth + Email)

- **Deep Link**: `syncoraplayer://login-callback` configurado en `AndroidManifest.xml` (Android) y Registro de Windows (desarrollo local).
- **Google OAuth**: Método principal vía `signInWithOAuth(OAuthProvider.google, redirectTo: 'syncoraplayer://login-callback')` y `AppLinks` deep link stream listener en `main.dart`.
- **Email/Contraseña**: Formulario secundario tabulado, sin confirmación por correo, con card de advertencia ámbar antes del envío notificando la falta de función "olvidé mi contraseña".
- **GoRouter Redirect**: Guardia global que exige sesión para navegar por la app (`/auth` fuera del `AppShell`). Respetada en `FLUTTER_TEST`.

---

## 3. Repositorios de Supabase y Sincronización Online-First

- **`SupabasePlaylistRepository`**, **`SupabaseAlbumRepository`**, **`SupabaseHistoryRepository`**: Operan exclusivamente con el cliente autenticado del usuario (`Supabase.instance.client`), garantizando que RLS restrinja las mutaciones.
- **`ConnectivityService`**: Stream reactivo (`isConnectedProvider`) para detección de red vía `connectivity_plus`.
- **`SyncService`**: Estrategia estricta Online-First:
  - Lecturas desde Drift local (0ms).
  - Al iniciar la app, recupera playlists, tracks y álbumes de Supabase y hace upsert en Drift.
  - Subida de historial de escucha local acumulado offline.
  - Escrituras bloqueadas en la interfaz cuando `isConnected == false`.

---

## 4. UI y Personalización de Avatares (DiceBear Adventurer Neutral)

- **`AvatarSelectorSheet`**: Grid de 24 semillas predefinidas usando la API de avatares `adventurer-neutral` de DiceBear renderizados con `flutter_svg`.
- **Header AppShell y SettingsScreen**: Muestra el avatar SVG del usuario según `profiles.avatar_seed`, con menú contextual para "Mi cuenta" y "Cerrar sesión".
- **LibraryScreen**: CRUD remoto/local de playlists con menú de 3 puntos (editar, eliminar, copiar enlace pública) y protección offline.

---

## 5. Verificación Automatizada y Auditoría de Código

- **`flutter analyze`**: **0 issues**
- **`flutter test`**: **56/56 pasando** (suites de Fases 1 a 5 combinadas)
- **Auditoría de Subagente**: Pasada con éxito verificando 0 llaves privadas en código, guards de conectividad en UI, respeto de `FLUTTER_TEST` y no duplicación de triggers DB en Dart.

---

## Pruebas para el Desarrollador (Humano)

Consulte la sección **Fase 5** en `docs/matriz_de_pruebas.md` para ejecutar la checklist manual de QA (Google Sign-In, Email Sign-Up, selector de avatares, guardias offline y validación de RLS).
