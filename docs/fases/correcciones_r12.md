# Duodécima ronda de correcciones (2026-11-21)

Sigue a la ronda 11 (todas sus pruebas en dispositivo pasaron). El "Jam" queda para después.

## Arreglos y cambios

1. **Deslizar la portada del reproductor a pantalla completa** cambia de canción (izquierda la
   siguiente, derecha la anterior), con la portada vecina entrando desde el borde. Es el mismo
   widget que el mini reproductor, renombrado de `MiniPlayerSwipeSkip` a **`SwipeToSkip`**
   (`swipe_to_skip.dart`), con los mismos umbrales (35 % del ancho, o 20 % con un lanzamiento en
   esa dirección). Aquí no recorta (`clip: false`) para no cortar el brillo de la portada. El
   arrastre vertical para cerrar el reproductor sigue igual: cada gesto gana solo en su eje.
2. **El aleatorio de las cabeceras solo cambia el modo.** En álbum (`album_detail_screen.dart`) y en
   las colecciones de catálogo (`collection_scaffold.dart`: álbumes de Deezer, mixes, artistas), el
   botón ponía la colección a sonar en aleatorio si no era la que sonaba. Ahora es
   `ShuffleToggleButton`, que solo llama a `toggleShuffle()`; el play ya respeta el modo (empieza en
   una canción al azar). Test: `shuffle_toggle_button_test.dart`.
3. **Aleatorio en la cabecera de playlist**, después de descargar. Para que la fila de móvil no
   crezca, el botón "Modificar con IA" sale de la fila en móvil (sigue en el menú de 3 puntos; en PC
   sigue en la fila, donde sobra espacio). La búsqueda dentro de la playlist ya estaba arriba a la
   derecha, sobre la portada, así que no hacía falta moverla. La fila es desplazable en horizontal,
   así que un título largo (que va arriba, aparte) nunca la encima.
4. **Resultados que cambiaban solos en "Agregar canciones" de una playlist.** Cada letra lanzaba una
   búsqueda a Deezer sin espera y las respuestas llegan en cualquier orden: la de "bad b" podía
   llegar después de la de "bad bunny" y reemplazar los resultados buenos segundos después. Ahora
   pasa por `LatestSearch` (`core/utils/latest_search.dart`): espera 400 ms sin teclas nuevas
   (Pitfall #4) y descarta toda respuesta que no sea de la última consulta. Test:
   `latest_search_test.dart`. El filtro de la lupa ("Buscar en esta playlist") es local y síncrono:
   no tenía este problema.
5. **Botón "+" junto al corazón en el reproductor a pantalla completa**: abre el mismo selector de
   varias playlists de la ronda 11. Apagado sin conexión, igual que el corazón. El título pierde
   48 px de ancho máximo (sigue siendo marquesina).

## Android Auto con el DHU

Instalado el Desktop Head Unit (`sdkmanager "extras;google;auto"`, queda en
`C:\Android\extras\google\auto\desktop-head-unit.exe`). Para usarlo:

1. Teléfono conectado por USB con depuración activa.
2. En la app Android Auto del teléfono (modo desarrollador ya activo): menú ⋮ → **Iniciar servidor
   de unidad principal**.
3. En la PC: `adb forward tcp:5277 tcp:5277` y luego `desktop-head-unit.exe`.

## Investigación: widgets de Android (sin implementar)

**Sí se puede.** Un widget de pantalla de inicio en Android es una vista nativa (`AppWidgetProvider`
+ `RemoteViews` en XML, o Jetpack Glance), no Flutter. Flutter solo le pasa datos.

### Qué tendría sentido
- **"Reproduciendo" (el principal)**: portada, título, artista y anterior / play-pausa / siguiente.
  Dos tamaños: 4×1 (barra) y 4×2 (con portada grande). Tocarlo abre la app.
- **Accesos a playlists**: un widget que abre "Tus me gusta" o una playlist elegida (deep link
  `syncoraplayer://playlist/...`, que ya existe). Más simple que el anterior.
- **Atajos del ícono** (mantener pulsado el ícono, no es un widget pero cuesta poco):
  "Tus me gusta", "Buscar", "Descargas", "Descubrir". Paquete `quick_actions`.

### Cómo se haría el de "Reproduciendo"
- **Datos**: el adaptador que ya publica al SO (`SyncoraAudioHandler`) escribe título, artista,
  ruta de la portada y si suena en `SharedPreferences` (paquete `home_widget`) y pide actualizar el
  widget **solo cuando algo de eso cambia** (regla de batería de la ronda 10; nunca la posición).
- **Botones**: mandan los mismos `KEYCODE_MEDIA_*` que los auriculares al `MediaButtonReceiver` de
  `audio_service`, que ya existe. No hace falta despertar Flutter en segundo plano para eso.
- **Portada**: archivo local (las portadas de descargas o una copia chica, ~300 px). `RemoteViews`
  tiene un tope de memoria para imágenes; una de 1000 px puede hacer que el widget no se pinte.
- **Release**: los drawables de los botones solo se nombran desde XML del widget, así que en
  principio R8 los ve; aun así, revisar `keep.xml` y probar en release (Pitfall #32).
- **Barra de progreso**: no conviene. Actualizarla cada segundo gasta batería y Android limita las
  actualizaciones de widgets; Spotify tampoco la pone en el suyo.

### Esfuerzo
- Atajos del ícono: chico (una tarde).
- Widget "Reproduciendo" 4×1 + 4×2 con `RemoteViews`: una ronda mediana (Kotlin + 2 layouts +
  publicador en Dart con test de "solo publica cambios" + pruebas en release en el teléfono).
- Glance (Compose) da esquinas y colores de Android 12+ más fácil, pero suma Compose al APK; con
  `RemoteViews` se logra casi lo mismo.
- Windows no tiene un equivalente útil (el panel de widgets de Windows 11 exige app empaquetada).

## Pruebas en dispositivo pendientes
- Android: deslizar la portada del reproductor a pantalla completa (y que bajar para cerrar siga
  funcionando), botón "+" del reproductor, aleatorio en álbum/playlist, "Agregar canciones" en una
  playlist escribiendo rápido.
- PC: aleatorio en álbum/playlist y "Agregar canciones".
- Android Auto en el DHU.
