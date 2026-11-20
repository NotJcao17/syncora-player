# Undécima ronda de correcciones (2026-11-20)

Después de la 1.2.0. Siete puntos del usuario: cinco arreglos, dos investigaciones (Android Auto y
"Jam").

## Arreglos

1. **El volumen no se aplicaba en Descubrir.** `PreviewPlayer` crea su propio motor de audio (Fase
   8.F: una preview no es una escucha) y nadie le pasaba el volumen del slider de la barra de PC, así
   que sonaba al 100 %. Ahora `PreviewPlayer.setVolume` lo guarda y lo aplica al motor nuevo y al
   actual, y `DiscoverFeed` sigue `engine.volume` del reproductor principal (también el silencio de
   la barra), incluso mientras suena la preview. Test: `preview_player_test.dart`.
2. **El aviso de "compartir = hacer pública" era muy ancho en PC.** Un `AlertDialog` con un texto
   largo se estira a casi todo el ancho de la ventana. El contenido ahora tiene `maxWidth: 420`
   (`playlist_share_service.dart`).
3. **Deslizar el mini reproductor (móvil) para cambiar de canción**, como Spotify: a la izquierda la
   siguiente, a la derecha la anterior. Se desliza solo la portada con el título (la canción vecina
   asoma desde el lado); el corazón y el play se quedan quietos. `mini_player_swipe.dart`.
   Para que no salte sin querer:
   - el gesto solo empieza si el dedo se mueve primero en horizontal (touch slop); un toque sigue
     abriendo el reproductor y un arrastre vertical no hace nada;
   - hace falta llevarla un 35 % del ancho, o un 20 % con un lanzamiento rápido en esa misma
     dirección; un roce corto, aunque sea rápido, no cuenta;
   - si no hay canción de ese lado (sin historial o cola vacía), el contenido se resiste y vuelve;
   - vibración corta al pasar el umbral.
   "Anterior" deslizando va **siempre** a la canción anterior (`skipToPrevious(restartIfPlayed:
   false)`): el gesto la enseña entrando, así que reiniciar la actual a los 3 s sería un engaño. El
   botón sigue igual. Tests: `mini_player_swipe_test.dart` y uno nuevo en el controlador.
4. **"Agregar a playlist" con selección múltiple** (`multi_playlist_picker.dart`): hoja deslizable en
   móvil y diálogo centrado en PC (`AppBottomSheet.show`), con buscador desde 7 playlists, "Nueva
   playlist" en línea (queda marcada) y un botón "Agregar a N playlists". Las que ya tienen la
   canción (mismo id **o** mismo título y artista, `PlaylistDao.playlistIdsContainingSong`) salen
   marcadas en gris y no se pueden elegir: con varias a la vez no hay un "¿agregarla de todos
   modos?" por cada una. **No** quita la canción de una playlist al desmarcarla (Spotify sí lo hace;
   no se pidió).
   La lógica de agregar (nube primero, subir una playlist local sin `remoteId`, límite de 10 000,
   "ya no existe en la nube") salió del diálogo a `add_to_playlist_service.dart`, sin cambios de
   comportamiento salvo que el `genre` ahora también se guarda en local. Una playlist que falla no
   detiene a las demás. Tests: `add_to_playlist_service_test.dart`.
   "Agregar todas a otra playlist" (desde una playlist) sigue con el selector simple.
5. **Hover del icono en la barra de tareas de Windows con la canción.** Lo que Windows muestra ahí (y
   en Alt+Tab) es el título de la ventana; la barra de título nativa está oculta, así que dentro de
   la app no cambia nada. `WindowsMediaControls` lo pone como `Título · Artista` cuando cambia la
   pista (también en pausa) y `Syncora Player` sin pista. Test: `windows_window_title_test.dart`.

## Android Auto: qué hay y por qué solo se veía anterior/siguiente

**Ya existe la navegación** (ronda 5, `SyncoraAudioHandler.getChildren`): Tus me gusta, Escuchado
recientemente, Tus playlists y Descargas; tocar una canción pone su playlist entera en la cola, y
"Ok Google, pon X en Syncora Player" busca en Deezer y reproduce (`playFromSearch`). Todo sale de
Drift, así que funciona sin conexión salvo la búsqueda.

**Por qué solo aparecían los controles:** Android Auto solo muestra en su lanzador las apps
instaladas desde Play Store. Una instalada desde el APK de GitHub no sale en la lista de apps del
coche; lo único que se ve es la tarjeta de "reproduciendo" de la sesión multimedia que ya suena
(anterior, play, siguiente). Para verla hay que activar en la app Android Auto: Ajustes → tocar 10
veces "Versión" → menú ⋮ → Ajustes de desarrollador → **Fuentes desconocidas**. Esto aplica a todos
los usuarios mientras la app no esté en Play Store (vale la pena decirlo en la web/README).

**Lo que falta / límites:**
- El botón de búsqueda dentro de la pantalla del coche necesita
  `android.media.browse.SEARCH_SUPPORTED = true` en los extras de la raíz. La ronda 5 quitó "el
  único valor no entero" de esos extras porque `AudioService.init` fallaba; no se volvió a poner sin
  probarlo en un dispositivo. La búsqueda por voz sí funciona sin él.
- Sin cuenta de Play Store no hay revisión de Google para apps de coche, así que no hay forma de que
  aparezca sin "Fuentes desconocidas".
- Spotify además tiene pestañas, recomendaciones y "me gusta" en el coche: lo nuestro se podría
  ampliar con más carpetas (mixes de Inicio, álbumes guardados) y acciones personalizadas, pero las
  reglas de distracción de Google limitan la profundidad y el número de elementos.

**Probarlo desde la PC (sin coche):** el Desktop Head Unit (DHU) del SDK de Android.
1. SDK Manager → SDK Tools → "Android Auto Desktop Head Unit Emulator" (o
   `sdkmanager "extras;google;auto"`), queda en `C:\Android\extras\google\auto\`.
2. En el teléfono: modo desarrollador de Android Auto (arriba), activar Fuentes desconocidas y, en el
   menú ⋮, "Iniciar servidor de unidad principal".
3. `adb forward tcp:5277 tcp:5277` y luego `desktop-head-unit.exe` desde esa carpeta. Se abre una
   ventana con la pantalla del coche manejada por el teléfono conectado por USB.
Docs: https://developer.android.com/training/cars/testing/dhu

## Investigación: "Jam" (sesión compartida)

Sin implementar. Idea: un dispositivo (anfitrión) crea una sesión; otros con la app se unen con un
código, enlace o QR y pueden agregar canciones a la cola y usar anterior/pausa/siguiente. Solo el
anfitrión reproduce (como Spotify Jam); los invitados son controles remotos.

### Lo que ya ayuda
- **El controlador ya recibe órdenes de fuera**: `SyncoraAudioHandler` (notificación, Android Auto)
  y `WindowsMediaControls` son adaptadores "orden externa → controlador". Un `JamHostAdapter` sería
  otro igual, sin tocar el controlador.
- **Lo que agrega un invitado va a la cola manual** (`addToQueue`), que ya es FIFO y sobrevive a
  todo (D-1). Basta con mandar el `SyncoraTrack` (metadatos de Deezer, JSON ya serializable por la
  sesión): el anfitrión extrae y reproduce.
- **El invitado busca con su propia app** (Deezer va por su IP); no gasta nada del anfitrión.

### Opción A (recomendada): Supabase Realtime Broadcast
Canal `jam:<código>`. Los invitados mandan órdenes (`add`, `play`, `pause`, `next`, `prev`); el
anfitrión las ejecuta y publica el estado (pista actual, sonando, posición, próximas 20 de la cola)
solo cuando cambia, más la posición cada ~10 s para la barra (el invitado interpola).

Números (plan gratis, verificados el 2026-11-20 en la página de límites de Supabase): 200 conexiones
simultáneas en el pico, 2 millones de mensajes al mes, 100 mensajes por segundo y 256 KB por
mensaje. Una sesión de 3 personas durante 2 h con ~1 cambio por canción y la posición cada 10 s son
unos 3 × 720 ≈ 2 200 mensajes entregados: hacen falta ~900 sesiones así al mes para llegar a los 2
millones. Las conexiones solo se abren durante un Jam, así que las 200 simultáneas no son el
límite real con 250 cuentas.

Seguridad: canales privados (autorización de Realtime con RLS sobre `realtime.messages`), así que
**hace falta cuenta** para anfitrión e invitados; el modo local no podría. No usar el inicio de
sesión anónimo de Supabase: crea filas en `auth.users` y se comería el cupo de 250 cuentas (el hook
de 7.H las cuenta). Una tabla `jam_sessions` (código, anfitrión, vence a las X h) y una migración.

### Opción B: misma red Wi-Fi, sin servidor
El anfitrión abre un servidor WebSocket en la red local (`dart:io`) y el invitado se conecta por QR
con IP y puerto. Sin cuenta ni costo, pero solo en la misma red, Windows pide permiso al firewall
la primera vez y muchas redes (universidad, hotel, datos móviles compartidos) aíslan a los clientes.
Más frágil para el usuario normal.

### Dificultades reales
- **Android en segundo plano**: la conexión del anfitrión tiene que sobrevivir con la pantalla
  apagada. El servicio en primer plano de audio mantiene vivo el proceso, pero hay que reconectar
  el canal al volver la red y reenviar el estado.
- **Quién manda**: el anfitrión también toca la cola; las órdenes del invitado se aplican en el
  orden en que llegan y la respuesta es el estado nuevo (sin conflictos porque solo un dispositivo
  modifica).
- **Permisos**: opción del anfitrión "los invitados solo pueden agregar" y expulsar.
- **Unirse**: enlace `syncoraplayer://jam/<código>` (ya hay deep links de playlist) y QR. Una página
  en la web para unirse desde el navegador sería extra.
- **UI**: hoja/diálogo "Iniciar Jam" con el código, aviso fijo "En un Jam", pantalla del invitado
  (reusa la cola y los controles), "agregada por X" en la cola.

### Esfuerzo estimado (opción A)
Una ronda mediana: migración + RLS de Realtime, `JamService` (anfitrión e invitado, con tests de
órdenes y estado con un canal falso), adaptador del anfitrión, deep link y tres piezas de UI. Lo más
delicado es la reconexión en Android y no publicar de más (Pitfall de batería de la ronda 10: solo
lo que cambia).

## Pruebas en dispositivo pendientes
- PC: volumen en Descubrir (mover el slider con una preview sonando, silenciar), aviso de compartir,
  título en el hover de la barra de tareas, selector de playlists (varias, nueva, buscador).
- Android: deslizar el mini reproductor (que no salte al hacer scroll ni al tocar), selector como
  hoja deslizable con el teclado abierto, y Android Auto con el DHU.
