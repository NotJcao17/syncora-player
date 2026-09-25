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

## Pasos manuales para el desarrollador

- Aplicar la migración nueva de eliminar cuenta (`supabase db push`).
- Desplegar la Edge Function (`supabase functions deploy ai-assistant`): cambian el prompt de
  cantidad y la búsqueda por letra.
