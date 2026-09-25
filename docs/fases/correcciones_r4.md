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
  Deezer (`artist:"X" track:"Y"`) **ya no devuelve resultados** (verificado en vivo el 2026-09-25),
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
- **Licencia**: CC BY 4.0 con atribución a Juan Carlos Orozco (`LICENSE`, README y la pantalla
  "Créditos y licencia"). Nota: Creative Commons no recomienda sus licencias para software; se
  eligió igualmente por decisión del autor. Los componentes de terceros conservan su licencia.

## Despliegue

Hecho por el agente el 2026-09-25: migración `20250001000018_delete_my_account.sql` aplicada
(verificado: sin sesión la RPC responde `permission denied`) y `ai-assistant` desplegada con
`supabase functions deploy ai-assistant --use-api` (verificado: arranca y responde `unauthorized` sin
sesión). El camino con búsqueda de Google no se pudo ejecutar sin un JWT de usuario: queda para la
prueba en dispositivo. Si ese intento falla por cualquier motivo, la función repite sin búsqueda.
