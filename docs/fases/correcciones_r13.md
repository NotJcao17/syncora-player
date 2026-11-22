# Decimotercera ronda (2026-11-21): Android Auto tipo Spotify y widgets

Sigue a la ronda 12 (sus pruebas en dispositivo pasaron). El "Jam" sigue para después.

## Cambios

1. **"+" del reproductor a pantalla completa** con trazo continuo (`AppIcons.linear`, fuente
   `SolarLinear`): la versión broken del círculo llevaba un corte que no se parecía al resto.
2. **Android Auto tipo Spotify** (`os_controls/android_auto_browser.dart`). Antes: cuatro carpetas
   planas sin portadas. Ahora:
   - Tres pestañas (los hijos navegables de la raíz se dibujan como pestañas): **Inicio**
     ("Escuchado recientemente": playlists y álbumes por `lastPlayedAt`; "Tu música": Tus me gusta
     y las fijadas), **Biblioteca** (Tus me gusta, playlists sueltas, carpetas, álbumes guardados) y
     **Descargas**. Grupos con `CONTENT_STYLE_GROUP_TITLE_HINT`, colecciones en cuadrícula y
     canciones en lista.
   - Dentro de cada colección, primera fila **"Reproducir en aleatorio"** (activa el modo y empieza
     en una al azar) y luego las canciones. Tocar una pone la colección entera desde ahí y la marca
     como escuchada.
   - Listas cortadas en 400 filas (la respuesta viaja entera por Binder, tope ~1 MB); tocar o el
     aleatorio usan la lista completa.
   - Los álbumes guardados piden sus canciones a Deezer (la base local no las tiene): necesitan red.
   - **Botón de búsqueda** (`SEARCH_SUPPORTED: true` en los extras de la raíz). La ronda 5 lo había
     quitado sin verlo fallar; `audio_service` arma bien el booleano y el servicio arranca (verificado
     en el teléfono, Android 16).
   - Raíz de "recientes" (`AudioService.recentRootId`): devuelve la pista actual, para "reanudar".
3. **Portadas en Android Auto.** Android Auto **solo carga portadas de navegación con URIs locales**
   (`content://` o `android.resource://`): con la URL de Deezer salían cuadros grises.
   `CoverArtProvider` (paquete `syncora_android`, autoridad `${applicationId}.art`) recibe
   `content://…art/img/<url en base64url>` o `/file/<ruta>`, baja la imagen una vez a
   `cache/syncora_art/` y la sirve. Es público (lo lee el proceso de Android Auto), así que **solo
   acepta hosts de portadas** (dzcdn.net, deezer.com, ytimg.com, ggpht.com, googleusercontent.com,
   `syncora-images.*.workers.dev`), máximo 8 MB, `Content-Type` de imagen, y archivos dentro de los
   datos de la app. La cola publicada al SO también usa estas URIs; la pista actual no (la
   notificación la descarga `audio_service` con la URL).
4. **Widget "Reproduciendo"**: portada a un lado y título, artista y anterior / reproducir-pausar /
   siguiente al otro. Dos diseños según el alto (barra 4x1 y 4x2 con portada grande; en Android 12+
   con `RemoteViews` adaptables). Tocar el widget abre el reproductor a pantalla completa.
   - Dart publica **solo cuando cambia la pista o play/pausa** (`NowPlayingWidgetPublisher`), nunca
     la posición (batería, misma regla de la ronda 10). Entre pista y pista se cuenta como "sonando"
     para que el botón no parpadee. La portada sale de la caché de `audio_service` (no se baja dos
     veces) y se pinta reducida y redondeada (`ArtCache.roundedSquare`, tope de memoria de los
     widgets).
   - Los botones mandan la misma tecla multimedia que unos auriculares al `MediaButtonReceiver` de
     `audio_service`. **Con la app cerrada abren la app** en vez de reproducir: el reproductor se
     arma desde la interfaz de Flutter y despertarlo sin ella no está probado. Lo decide
     `WidgetBridge.playerAlive`, que marca Dart al quedar listo `audio_service`.
5. **Widget de playlist o álbum**: portada y nombre; tocarlo abre esa colección
   (`syncoraplayer://widget/playlist/<id local>` o `/album/<id de Deezer>`; los lee `main.dart` y los
   abre `AppShell` con `pendingWidgetRoute`, igual que las playlists compartidas).
   - Al ponerlo desde el launcher se abre "¿Qué abre este widget?" (`CollectionConfigActivity`,
     nativa): la lista la publica la app al cambiar la biblioteca (`LibraryWidgetPublisher`), así que
     no abre la base ni arranca Flutter. Se puede volver a elegir (`reconfigurable`).
   - Desde la app: **"Agregar a la pantalla de inicio"** en el menú de 3 puntos de una playlist
     (`requestPinAppWidget`; el launcher avisa con el id del widget a `WidgetActionReceiver`). El
     álbum no tiene menú: los álbumes **guardados** salen en la lista del widget.
   - Si la playlist cambia de nombre o portada, los widgets se actualizan solos.

## Paquete `packages/syncora_android`

Plugin local (solo Android) con todo lo nativo de esta ronda: proveedor de portadas, los dos
widgets, la pantalla de elegir y el receptor de botones. Se hizo plugin, y no código en
`MainActivity`, porque **la actividad de inicio de la app es `AudioServiceActivity`** (de
`audio_service`): cambiarla por una propia borraría el ícono que los usuarios tienen en la pantalla
de inicio. Los recursos llevan prefijo `syncora_widget_` y se nombran desde XML/`R`, así que el
reductor de release no los borra (verificado: `dumpsys appwidget` muestra los dos proveedores con
su layout en el APK de release).

## Pruebas automatizadas
- `android_auto_browser_test.dart`: pestañas, orden de "Escuchado recientemente", carpetas,
  portadas `content://`, corte en 400 filas y "Reproducir en aleatorio".
- `home_widgets_test.dart`: el widget solo se publica con cambios reales (no con la posición), una
  portada que llega tarde no pisa la pista nueva, lista de colecciones y enlaces de los widgets.

## Verificado en el teléfono (APK de release)
- El proveedor devuelve un JPEG real para una portada de Deezer y rechaza un host ajeno.
- Los dos widgets aparecen registrados; el servicio de audio arranca con `SEARCH_SUPPORTED`.
- El enlace `syncoraplayer://widget/player` llega a la app.

## Pruebas en dispositivo pendientes
- Android Auto en el DHU: pestañas, portadas, aleatorio, abrir un álbum guardado, búsqueda.
- Widget "Reproduciendo": botones con la app abierta, en segundo plano y cerrada; cambiar de tamaño.
- Widget de colección: ponerlo desde el launcher (elegir), desde el menú de una playlist, tocarlo.
- El "+" del reproductor.
