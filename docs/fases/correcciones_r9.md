# Novena ronda de correcciones (2026-10-15)

Primera ronda tras publicar la 1.1.0. Cada bundle cierra con `flutter analyze` limpio, la suite
completa en verde (852 tests), commit y push. Sin migraciones ni cambios en Supabase.

**Estado: publicada en la 1.2.0 (2026-10-22).**

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
- **H-R9-2. "YouTube pidió verificar esta conexión" en todas las canciones con datos móviles, hasta
  reiniciar el teléfono.** El motor crea una instancia de Innertube por cliente
  (`globalThis._ytInstances` en `engine/src/glue.js`) con su `visitorData`, y `DartFetchBridge`
  guarda las cookies de YouTube (`VISITOR_INFO1_LIVE`, etc.); las dos duraban lo que el proceso:
  nada llamaba a `resetEngine()` y el isolate solo se recrea al morir o al cambiar de motor.
  Reiniciar cambió a la vez la sesión y probablemente la IP de la red móvil, así que no se sabe cuál
  de las dos lo arregló. Arreglo: ante "not a bot", `YoutubeSessionRefresher` borra las instancias de
  Innertube y las cookies y se reintenta el mismo video una vez antes de pausar. Tiene un
  enfriamiento de 1 min: si la sesión recién renovada también lo pide, es la IP, y renovar en cada
  canción solo sumaría peticiones mientras siga bloqueada (después sigue lo de H-R8-4: un candidato
  más y pausa). Los tests cubren el enfriamiento y el borrado de cookies; el camino completo necesita
  QuickJS y se prueba en el dispositivo. Si vuelve a pasar con datos y el reintento no lo arregla, es
  la IP: modo avión unos segundos le da una nueva.

## Pruebas en dispositivo pendientes

- **Letras:** abrir la letra de "Don't Stop Me Now" (Queen) y "I Just Might" (Bruno Mars). Si
  LRCLib sigue limitando, puede tardar unos segundos; si sale "sin letra", cerrar y volver a abrir
  la hoja debe volver a pedirla (antes quedaba sin letra hasta reiniciar la app).
- **"No eres un bot":** si vuelve a aparecer con datos móviles, el registro de `/debug` debe mostrar
  "se renueva la sesión y se reintenta". Si después de eso sigue pausando, es la IP (modo avión unos
  segundos). Comprobar que no se renueva en bucle: como mucho una vez por minuto.

