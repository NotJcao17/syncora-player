# Séptima ronda de correcciones (2026-10-08)

Versiones de recopilación en el buscador, "Crear cola con IA" fuera de tema y búsqueda por letra.

## Hallazgos verificados

- **H-R7-1. La búsqueda de Deezer da la versión de una recopilación.** "hips don't lie" →
  "Filtr presents R&B Party"; "waka waka" → "Party Hits: Summer Edition". La versión del álbum
  del artista existe con el **mismo ISRC** (*Oral Fixation, Vol. 2*, id 3389132901), pero `/search`
  no la incluye entre los primeros 100, y `/artist/{id}/top` y `/track/isrc:` devuelven también la
  de la recopilación. Arreglo: `CanonicalVersionResolver` (detalle y límites en
  `docs/fuentes_youtube_y_matching.md` §3, que antes lo daba por no implementable).
- **H-R7-2. "Crear cola con IA" se salía del pedido tras la primera canción.** Mismo modelo que
  "Crear playlist", que sí funcionaba. Diferencias: el esquema de playlist obliga a escribir
  `playlistName` y `description` antes de `tracks` (ancla el tema); el de cola pedía solo
  `tracks`. El prompt de cola no decía que el pedido manda sobre el contexto (el de playlist sí),
  y las rondas de relleno mandaban lo ya sugerido como `contextTracks` ("continúa esto") en vez de
  "no repitas esto". Arreglo: campo `theme` antes de `tracks`, prompt con la regla "cada canción
  cumple el pedido" y campo nuevo `excludeTracks`. **No se pudo medir contra Gemini desde el
  entorno del agente** (sin llave); confirmarlo en la prueba manual.
- **H-R7-3. La búsqueda por letra nunca usaba la búsqueda de Google.** La búsqueda de Google
  (grounding) **no está disponible en el plan gratuito** de Gemini (página de precios,
  columna Free Tier: "Not available"). Cada búsqueda fallaba primero y caía al modelo Lite sin
  búsqueda, que casi no reconoce letras. Arreglo: sin grounding, mismo modelo Lite, pide de 3 a 5
  candidatos y el cliente los comprueba contra la letra real de LRCLib (`LyricMatch`, por pares de palabras): los que
  coinciden van primero bajo "La letra coincide". Botón "Buscar otra" sin cerrar la hoja.

## Descartado

- **Gemini Flash para la letra** (se probó y se quitó antes de desplegar, decisión del usuario):
  Google ya no publica los límites gratuitos por modelo (solo se ven en AI Studio) y podía agotar
  la llave compartida. Se prueba primero Lite con 5 candidatos y la verificación de LRCLib.
- **Más resultados o álbumes en el resolvedor.** Costo medido en vivo (8 búsquedas populares,
  caché vacía): sin filtros, 5 a 15 peticiones extra por búsqueda; con los filtros de sencillo
  propio y discos en vivo, 1 a 10 con las mismas correcciones. Limitarlo a 5 resultados bajaba a
  1-8 pero perdía Billie Jean y Corazón Partío. En una lista de IA de 25 canciones sin álbum: unas
  26 peticiones extra (3-4 s más); con álbum en el CSV, cero.
- **Buscar la letra en LRCLib o Genius directamente.** `lrclib.net/api/search?q=` solo busca en
  título, artista y álbum, no en la letra. `genius.com/api/search/lyrics` responde 403
  (Cloudflare) fuera de un navegador.
- **Pedirle el álbum a la IA.** El resolvedor ya corrige la versión con datos de Deezer; un álbum
  inventado por la IA solo sumaría búsquedas de álbum por pista.

## Despliegue

La Edge Function `ai-assistant` cambió (prompts, esquema de cola, `excludeTracks`, sin
búsqueda de Google). Es compatible con la app anterior. Desplegada por el agente el 2026-10-08
y verificada (lo publicado coincide con el repo).
