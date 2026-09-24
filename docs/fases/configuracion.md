# Configuración: persistencia, almacenamiento, temporizador y aviso legal

Sesión del 2026-09-24. Cuatro bundles, cada uno con `flutter analyze` limpio y la suite completa en
verde antes de su commit.

## Hallazgos verificados (leyendo código)

- **H-C1. Los ajustes no persistían.** Radio, crossfade y "Descargar solo con Wi-Fi" eran
  `StateProvider` en memoria. La calidad de descarga sí persistía, pero en `flutter_secure_storage`.
- **H-C2. "Borrar caché de portadas" borraba lo que no debía.** `CoverCacheService.currentSizeBytes`
  devolvía `0` fijo (de ahí el "0.0 MB"), y `clear()` vaciaba `syncora/covers`, que solo contiene
  las **portadas de las pistas descargadas** (las que se ven offline). La caché real de imágenes de
  navegación es la de `CachedNetworkImage` (`DefaultCacheManager`, en
  `getTemporaryDirectory()/libCachedImageData`), que nunca se medía ni se borraba.
- **H-C3. La barra de almacenamiento se comparaba contra un tope inventado de 500 MB.**
- **H-C4. "Descargar solo con Wi-Fi" no hace nada en escritorio** (`DownloadService._checkWifiGuard`
  lo salta a propósito), pero el toggle se mostraba igual.
- **H-C5. Las etiquetas de calidad prometían de más.** "Alta" decía "~160-256 kbps": YouTube sin
  Premium llega a ~160 kbps (Opus 251). En Android solo se aceptan formatos MP4/AAC
  (`js_bundle_loader.dart`), así que "Alta" y "Normal" suelen acabar en el mismo itag 140 (~128 kbps).
  La calidad solo aplica a descargas nuevas, no al streaming.
- **H-C6. `profiles.download_wifi_only` (Supabase) no la usa ningún código.**

## Decisiones cerradas

- **Todos los ajustes son del dispositivo, no de la cuenta** (decisión del usuario). Wi-Fi y
  calidad dependen del hardware y la red de cada equipo, y así el modo local se comporta igual.
  `profiles.download_wifi_only` queda sin uso a propósito; no se hizo migración para borrarla.
- **Persistencia con `shared_preferences`** (ya era dependencia transitiva vía `supabase_flutter`,
  no entra ningún plugin nativo nuevo), en `lib/core/settings/app_settings_store.dart`. Se carga en
  `main.dart` antes de `runApp`: el controlador del reproductor lee radio/crossfade con `ref.read`
  en cualquier momento y nunca debe ver el valor por defecto mientras carga. La calidad se migra una
  vez desde `flutter_secure_storage` (clave `syncora_download_quality_v1`) y se borra de ahí.
- **Ecualizador descartado** (no entra en la Fase 8) y su botón "Próximamente" quitado. Motivo: en
  Windows tendría que ir por un filtro `af=lavfi=[...]` de libmpv, el mismo mecanismo que rompió
  Skip Silence; en Android el crossfade usa dos `AudioPlayer`, así que habría que mantener dos
  `AndroidEqualizer` sincronizados. Nada de eso se puede validar con tests automáticos.
- **Temporizador de apagado fuera del controlador** (`lib/features/player/sleep_timer.dart`): no
  toca cola ni avance de pista, solo observa `playerStateProvider` y pausa con
  `userInitiated: true`. Por tiempo: fade de 8 s, pausa y restaura el volumen. "Al terminar la
  canción": pausa a 1,2 s del final; si la pista cambia antes (salto o crossfade), pausa cuando la
  nueva ya suena. Pausar mientras todavía carga no sirve: el `play()` pendiente del controlador la
  reanudaría.
- **Aviso legal** (`legal_screen.dart`, ruta `/legal`): texto estático que describe lo que la app
  hace hoy. Si cambia qué se guarda o a qué servicio se habla, el texto tiene que cambiar con ello.
  **Excepción deliberada:** el texto ya dice que la cuenta se puede eliminar desde Configuración,
  aunque ese botón todavía no existe. Se implementa en la fase siguiente (decisión del usuario); hasta
  entonces, esa frase del aviso no es cierta.

## Pruebas manuales pendientes (Android y Windows)

1. Cambiar radio, crossfade, Wi-Fi (Android) y calidad; cerrar la app por completo y reabrir: deben
   conservarse. En una instalación con calidad elegida antes de esta sesión, debe conservarse.
2. Configuración → almacenamiento: el total ya no es 0 y "Borrar caché de imágenes" lo baja. Tras
   borrarla, las portadas de canciones descargadas deben seguir viéndose en modo avión.
3. Temporizador de 5 min: la música baja de volumen gradualmente y se pausa; al reanudar, el volumen
   es el de antes. "Al terminar la canción" con y sin crossfade: se detiene al final y, al darle a
   play, sigue la siguiente. Cancelarlo desde Configuración, el menú del reproductor (móvil) y el
   botón de luna de la barra inferior (PC).
4. Revisar el texto de "Privacidad y aviso legal".
