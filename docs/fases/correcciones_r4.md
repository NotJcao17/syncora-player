# Cuarta ronda de correcciones (pre-Fase 8)

Sesión del 2026-09-25. Plan, diagnóstico y estado. Siete bundles, cada uno con `flutter analyze`
limpio y la suite en verde antes de su commit.

## Diagnóstico (leyendo código)

- **H-R4-1. "Next" arranca en el segundo donde iba la pista anterior.** `_restoredPositionSeconds`
  (posición de la sesión restaurada) solo se limpiaba en `setQueue`/`playFromQueue`. Al reabrir la
  app y pulsar "siguiente" sin haber reproducido la pista restaurada, `_playCurrentGuarded` aplicaba
  esa posición a la pista nueva: no comprobaba que fuera la misma pista.
- **H-R4-2. Play "de la nada".** Si el motor reporta un error de fuente estando en pausa (URL
  caducada, cambio de red mientras bufferiza), `_onEngineState` hacía `_advanceAndPlay()`: saltaba
  y **reproducía** la siguiente. También una completion espuria con la pausa causada por el sistema
  (no por el usuario) pasaba el guard de `_onComplete`.
- **H-R4-3. "No se pudo iniciar" al reabrir.** El único reintento de carga reusaba **la misma URL**.
  Si la URL no sirve (atada a IP/red, caducada), el reintento falla igual. Ahora el reintento pide
  una URL nueva a la extracción.
- **H-R4-4. Corazón vacío tras dar like desde la pantalla de bloqueo.** El reproductor a pantalla
  completa consultaba "me gusta" una sola vez por pista; no observaba la base de datos.
- **H-R4-5. Error rojo de `Dismissible` en la cola.** Las keys de fila eran `id + ocurrencia`: al
  quitar una pista repetida, la siguiente copia heredaba la key del `Dismissible` ya descartado. Y
  el índice capturado al construir podía apuntar a otra pista si la cola avanzó durante el gesto.
- **H-R4-6. Encolar sin querer al hacer scroll.** El `Dismissible` acepta el gesto horizontal al
  mismo umbral (18 px) que el scroll vertical, y un "fling" diagonal lo confirma aunque no llegue al
  umbral. Se sustituye por un reconocedor propio que exige empezar en el borde izquierdo y
  dominancia horizontal clara.
- **H-R4-7. Tirones al abrir el teclado y al hacer scroll.** 37 widgets usaban
  `MediaQuery.of(context).size`, que reconstruye con **cualquier** cambio del `MediaQuery`
  (incluido cada frame de la animación del teclado); entre ellos cada `TrackTile` de las pantallas
  que quedan debajo. Además cada portada hacía un `existsSync()` en disco por build.
- **H-R4-8. "Tus me gusta" y "On Repeat" siempre arriba.** Se creaban con `isPinned = true` y la
  biblioteca pone las fijadas primero. El sync nunca leía `is_pinned` de Supabase.
- **H-R4-9. Búsqueda más lenta.** Desde A5b se enriquecen siempre los 5 primeros resultados con
  `/track/{id}` antes de mostrar nada: una ida y vuelta completa más. Pasa a segundo plano.
- **H-R4-10. Descargas concurrentes del mismo archivo.** Sin cerrojo por `trackId`.
- **H-R4-11. Importación lenta y atada al diálogo.** Secuencial con 200 ms de pausa extra, más una
  petición de colaboradores por pista, y todo dentro de un diálogo modal: cerrar la app perdía todo.
- **H-R4-13. La importación metía versiones y artistas equivocados.** La sintaxis avanzada de
  Deezer (`artist:"X" track:"Y"`) **ya no devuelve resultados** (verificado en vivo el 2026-09-25).
  **Fue un cambio del lado de Deezer, no de nuestro código:** la consulta es idéntica desde la Fase B
  (en esta ronda solo se le añadió `enrich: false`, que no toca la búsqueda) y en agosto esa misma
  sintaxis acertaba 10/10 y encontraba "Someone Like You" de Adele en la posición 1
  (`plan_buscador_importacion_matcher.md`). Hoy Deezer ya no reconoce el operador `artist:`: lo trata
  como la palabra "artist" y busca títulos que la contengan (`artist:"ABBA"` devuelve canciones de
  Hisham Abbas; `artist:"Adele"`, "Starving Artist"). `track:` y `album:` siguen funcionando. La
  debilidad de fondo sí era nuestra: los tiers de respaldo elegían por duración sin mirar el
  artista, y eso solo se vio cuando el primer tier dejó de funcionar. El tier avanzado también se
  quitó de `ExactTrackSearch` (pestaña "Exacta" de Búsqueda profunda), donde gastaba una petición
  inútil.
  así que todo caía a la búsqueda de texto y se elegía la pista de duración más parecida **sin mirar
  el artista**: un 8-bit, un karaoke o un cover de duración casi igual ganaban al original. Además
  algunos artistas (Adele) no salen en la búsqueda de canciones de la API pública, pero sí sus
  álbumes y su discografía. `ImportTrackMatcher` exige el mismo artista, descarta karaokes/covers/
  tributos, penaliza versiones que el archivo no pedía, usa el álbum del CSV (búsqueda de álbumes y,
  si no, la discografía del artista) y prefiere dejar la fila como "no encontrada" antes que meter
  otro artista. Probado en vivo con 36 canciones reales (las de la playlist del reporte y
  `docs/test.csv`): 36 correctas, todas con el álbum original.
- **H-R4-12. IA genera menos canciones de las pedidas.** El prompt decía que "no hace falta que la
  cifra sea exacta" y la cantidad solo viajaba como dato del usuario.

## Bundles

1. **Biblioteca y playlists:** fijar playlists (local + Supabase + sync), "Tus me gusta"/"On
   Repeat" como playlists normales, vista y orden persistentes, barra lateral sin descripción y con
   el mismo orden, insignia de descargas compacta, selector compacto en "Agregar todas".
2. **Reproductor:** H-R4-1 a H-R4-4 y artista clickeable en pantalla completa.
3. **Listas, gestos y rendimiento:** sin números en móvil, gesto de encolar estricto, arreglo de la
   cola (H-R4-5), deslizar a la derecha en la cola, H-R4-7, ícono de "ya en tu biblioteca", barra
   gris del artista, hoja de "Mejorar cola con IA".
4. **Búsqueda:** enriquecimiento en segundo plano y aviso del filtro "Popular".
5. **Descargas e importación:** cerrojo por pista; importación en segundo plano, concurrente,
   reanudable tras cerrar la app y cancelable.
6. **IA:** cantidad exacta (prompt + ronda de relleno en el cliente) y búsqueda por letra.
7. **Cuenta y legal:** eliminar cuenta (RPC nueva) y créditos + licencia CC BY 4.0.

## Estado

Los siete bundles están implementados, con `flutter analyze` limpio y la suite completa en verde
(635 tests al cerrar). Faltan las pruebas en dispositivo.

## Decisiones de esta ronda

- **Fijar viaja a Supabase** (`playlists.is_pinned`, columna que ya existía) y el sync la lee. "Tus
  me gusta" y "On Repeat" se desfijan una vez (migración Drift v12) y se ordenan como cualquier
  otra. Orden y vista de Biblioteca son ajustes del dispositivo (`library.sort`,
  `library.grid_view`); la barra lateral usa el mismo orden.
- **Deslizar a la derecha solo empieza en el 30 % izquierdo de la pantalla** y exige un gesto
  claramente horizontal; nunca cuenta la velocidad. En la cola, deslizar a la derecha **mueve** una
  pista de la cola automática a "A continuación" (no la duplica).
- **Un error del motor en pausa ya no salta de pista**: deja la pista lista para reintentar en el
  mismo segundo al pulsar play.
- **Importar**: la playlist se crea al empezar y se llena por bloques de 10. Cada bloque sube a la
  nube antes de insertarse en local (la nube nunca tiene menos que el dispositivo). Si la nube
  rechaza un bloque, la importación se pausa; si se pierde la conexión, se pausa y se reanuda sola
  al volver. El trabajo se guarda en `syncora/imports/` y se reanuda al abrir la app. En Android, si
  el sistema congela la app en segundo plano, la importación se detiene hasta que vuelva a primer
  plano, y sigue donde iba.
- **IA, cantidad**: el servidor añade una instrucción de cantidad construida con el `count` ya
  validado (nunca texto del usuario), y el cliente hace hasta dos rondas de relleno
  (`modify_playlist_add`) cuando, tras matchear con Deezer, faltan canciones. Una cantidad escrita en
  el texto ("50 canciones") cuenta igual que el preset.
- **IA, letra**: `lyric_search` activa la búsqueda de Google (grounding). Si el modelo no admite
  herramienta + salida estructurada (HTTP 400) o la respuesta no se puede leer, repite sin ella.
- **Eliminar cuenta**: RPC `delete_my_account()` (SECURITY DEFINER, sin parámetros, solo borra
  `auth.uid()`); el `ON DELETE CASCADE` borra todo lo del usuario y libera su cupo. Después se limpia
  la biblioteca local (las descargas se conservan) y se cierra la sesión.
- **Licencia: GPL v3**, copyright de Juan Carlos Orozco (`LICENSE` con el texto oficial, README y la
  pantalla "Créditos y licencia"). Primero se puso CC BY 4.0; el autor cambió a GPL v3 para que nadie
  pueda distribuir una versión cerrada. Las dependencias (MIT, Apache, BSD, LGPL; los íconos Solar y
  el estilo de avatar en CC BY 4.0) son compatibles y conservan su licencia.

## Despliegue

Hecho por el agente el 2026-09-25: migración `20250001000018_delete_my_account.sql` aplicada
(verificado: sin sesión la RPC responde `permission denied`) y `ai-assistant` desplegada con
`supabase functions deploy ai-assistant --use-api` (verificado: arranca y responde `unauthorized` sin
sesión). El camino con búsqueda de Google no se pudo ejecutar sin un JWT de usuario: queda para la
prueba en dispositivo. Si ese intento falla por cualquier motivo, la función repite sin búsqueda.

## Segunda tanda (tras la primera prueba en dispositivo)

- **H-R4-14. 1-2 canciones "no encontradas" siempre, fueran 10 o 600.** Los colaboradores separados
  por coma ("Rihanna, Calvin Harris"; así los manda la IA y algunos exportadores) no coincidían con
  ningún artista: solo se partía por ";". Ahora se parte por `; , & feat. x y with and` y se conserva
  el nombre completo para dúos ("Jesse & Joy").
- **H-R4-15. Una canción de la mitad "colada" al principio de la importación.** El sync de la
  playlist (se dispara al abrirla, justo después de empezar a importar) insertaba por su cuenta las
  pistas que la importación acababa de subir, y ambas escrituras se pisaban. `SyncLocks` hace que el
  sync se salte una playlist mientras se importa. Además las filas remotas se guardaban todas con
  `order_index = 0` (orden arbitrario en otro dispositivo); ahora llevan su posición real.
- **Deezer, sintaxis avanzada:** confirmado externamente. SoulSync #1295 (abierto el 2026-09-23)
  reporta lo mismo: `artist:"X" track:"Y"` devuelve 0 sin error. La forma mixta
  `X track:"Y"` sí funciona y además devuelve artistas ocultos de la búsqueda normal (Adele), así que
  sustituye al tier roto en `ExactTrackSearch` y se usa como segunda consulta en
  `ImportTrackMatcher`. La pestaña "Exacta" de Búsqueda profunda pide también el matcher y ordena:
  su mejor coincidencia, luego el mismo artista, luego el resto.
- **H-R4-16. Portadas caídas.** Deezer da de baja versiones (`readable: false`) y su portada redirige
  a una imagen vacía (`…/cover/d41d8cd98f00b204e9800998ecf8427e/…`). `CoverRepairService` revisa una
  vez por semana cada portada distinta de la biblioteca con un `HEAD` al CDN y sustituye las caídas
  por la de la misma canción (vía `ImportTrackMatcher`), en local y en Supabase.
- **H-R4-17. Crash "keyReservation" al ir al artista desde la cola.** `context.push` de una ruta del
  shell con la hoja de cola y el reproductor a pantalla completa (ruta raíz) encima dejaba la página
  del shell dos veces en el `Navigator`. `navigateSafely` cierra lo de encima antes de navegar; "Ir
  al artista" deja elegir si hay varios.
- **IA:** intercalado fijo 2:1 desde el principio de la cola (decisión del usuario; el adaptativo
  de H-8 diluía 25 sugerencias en 600 pistas). "Mejorar cola" descarta lo que ya está en la cola o
  en la playlist y hace una ronda de relleno. "Modificar playlist → agregar" descarta lo que la
  playlist ya tiene. "Basado en una playlist" ya no copia canciones de la referencia y el pedido
  manda sobre ella. Guardar una playlist de IA resuelve colaboradores en paralelo e inserta en lote.
- **Rendimiento:** la paleta de color se calcula sobre la portada a 64x64 desde la caché y se
  memoriza (antes, portada completa en el hilo de la UI al abrir cada playlist/álbum/reproductor);
  el teclado solo desplaza la hoja de arriba.
- **Cola completa vs. por bloques:** se mantiene la cola automática completa (600 pistas en
  aleatorio). Paginarla de 50 en 50 tocaría las invariantes de la cola dual (D-1, regenerar,
  aleatorio) sin ganancia real: la lista ya se construye de forma perezosa. Las sugerencias de IA
  viven en la cola automática, que se guarda con la sesión, así que sobreviven a reiniciar la app;
  regenerar la cola o cambiar el aleatorio sí las descarta.

## Tercera tanda

- **H-R4-17 (corrección real).** La primera versión de `navigateSafely` no arreglaba nada: detectaba
  el reproductor con `currentConfiguration.uri`, pero tras `push('/player')` GoRouter sigue
  reportando la `uri` de la pantalla base (`/`). Nunca cerraba el reproductor y el shell se apilaba
  encima igual. Ahora se mira la última ruta de la pila (`matches.last.matchedLocation`), se espera
  a que el `pop` se procese y después se hace el `push`. Reproducido y cubierto en
  `test/core/navigation/safe_navigation_test.dart` (desde el reproductor y desde una hoja encima).
- **H-R4-18. Las portadas se volvían a descargar en cada arranque.** `DefaultCacheManager` guarda
  como máximo 200 imágenes: una playlist de 600 ya la desbordaba. `AppImageCache` (2500 imágenes,
  60 días) se usa en todos los `CachedNetworkImage`; "Borrar caché de imágenes" vacía las dos. La
  animación de entrada de las miniaturas bajó de 500 ms a 120 ms (se reproducía también al leer de
  disco).
- Importaciones simultáneas: máximo 2 activas (las pausadas cuentan); una tercera muestra un aviso.
- Las descargas de una playlist siguen el orden original, no el orden visible.
- El reparador de portadas corre **en la app**, no en el servidor: al arrancar, si pasaron 7 días
  desde la última pasada (la fecha se guarda en los ajustes del dispositivo).

## Cierre de la ronda (2026-09-25)

Pruebas en dispositivo pasadas por el usuario, salvo lo que queda abajo. Todo commiteado y
pusheado a `master`.

### Pendientes para la siguiente fase

1. **Tirones al abrir y al hacer scroll en playlists grandes (~600 canciones).** Mejoró (caché de
   portadas de 2500 y paleta a 64x64), pero los primeros segundos tras abrirla todavía va trabada, y
   dos veces el toque para detener el scroll disparó un "play". El log muestra
   `Choreographer: Skipped 33 frames`, trabajo en el hilo de la UI. Sospechosos a medir con DevTools
   (perfil en `--profile`, no en debug) antes de tocar nada:
   - el mapeo `PlaylistTrack -> SyncoraTrack` con un `jsonDecode` de colaboradores por fila (ya se
     memoriza, pero la primera vez corre entero en el hilo de la UI);
   - la decodificación de las miniaturas que entran de golpe al abrir;
   - los `StreamBuilder` de Drift de las cabeceras (contadores, portada en cuadrícula) que se
     re-emiten mientras la playlist carga.
   Para el "play" accidental: que el toque sobre una fila no dispare reproducción si llegó mientras
   la lista todavía se movía (Flutter ya lo hace con el scroll en curso; revisar el `InkWell` de
   `TrackTile` y el `SwipeActionTile`).
2. **Teclado trabado en "Mejorar cola con IA".** El usuario va a rediseñar esa función en la
   siguiente fase; no se tocó más.
3. **"No se pudo iniciar" al reabrir:** no se volvió a reproducir tras H-R4-3. Si reaparece, pedir
   las líneas `[Play]` de la consola.

