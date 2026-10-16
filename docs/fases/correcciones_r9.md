# Novena ronda de correcciones (2026-10-15)

Primera ronda tras publicar la 1.1.0. Cada bundle cierra con `flutter analyze` limpio, la suite
completa en verde, commit y push.

## Hallazgos verificados

- **H-R9-1. Canciones sin letra aunque LRCLib sí la tiene** ("Don't Stop Me Now" de Queen, "I Just
  Might" de Bruno Mars). No era la búsqueda: las dos están en LRCLib con duraciones a ±2 s de las de
  Deezer (212 s contra 209-214 s), así que `/get` las encuentra. Lo que pasa es que LRCLib está
  respondiendo **429 con `Retry-After: 1`** a casi todo (medido el 2026-10-15 desde la red de la casa
  y desde otra IP; contestaba al 4.º-5.º intento, a los ~8 s), y `LRCLibApi` guardaba ese fallo en
  su caché en memoria como "sin letra": la canción quedaba sin letra hasta reiniciar la app. Arreglo:
  solo se cachea una respuesta definitiva (letra encontrada, o 404 de `/get` y `/search` vacío); ante
  429/503 se reintenta hasta 4 veces esperando `Retry-After` (mínimo 1, 2, 3 s); y las peticiones
  llevan `User-Agent`, como pide LRCLib. La letra solo se pide con la vista de letra abierta (hoja en
  móvil, panel en PC) o en la búsqueda por letra; no en cada cambio de canción.

## Pendiente (diagnosticado, sin cambios aún)

- **"YouTube pidió verificar esta conexión" en todas las canciones con datos móviles, hasta
  reiniciar el teléfono.** El motor crea una instancia de Innertube por cliente
  (`globalThis._ytInstances` en `engine/src/glue.js`) con su `visitorData`, y la reutiliza mientras
  viva el proceso: nada llama a `resetEngine()` y el isolate solo se recrea al morir o al cambiar de
  motor. Reiniciar cambió a la vez la sesión (nuevo `visitorData`) y probablemente la IP de la red
  móvil, así que no se sabe cuál de las dos lo arregló. Arreglo propuesto: ante "not a bot",
  reiniciar las instancias de Innertube y reintentar una vez antes de pausar. Para distinguir la
  causa la próxima vez: primero cerrar la app (si se arregla, era la sesión); si no, modo avión unos
  segundos (IP nueva).
