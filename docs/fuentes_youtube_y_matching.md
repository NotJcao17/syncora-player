# Fuentes de audio y matching: cuándo YouTube y cuándo YouTube Music

Documento pedido en la ronda de QA posterior a la Fase 7: no estaba escrito en
ningún lado cuándo la app usa YouTube "normal" y cuándo YouTube Music, y esa
confusión hace imposible razonar sobre por qué a veces suena una versión
equivocada.

**Resumen en una línea:** no son dos fuentes alternativas entre las que la app
elija — YouTube es siempre la fuente del **audio**, y YouTube Music es solo una
**fuente extra de candidatos** dentro de la misma búsqueda, que se consulta
únicamente cuando la búsqueda de vídeos devuelve pocos resultados.

---

## 1. El flujo completo, paso a paso

Todo esto vive en `lib/core/extraction/`:

| Archivo | Rol |
| :--- | :--- |
| `extraction_isolate.dart` | Orquesta la resolución y la extracción, en un isolate dedicado (Pitfall #8) |
| `js_bundle_loader.dart` | Define las funciones JS (`searchVideos`, extracción) que corren en QuickJS |
| `yt_search_matcher.dart` | Puntúa los candidatos y elige cuál se reproduce |

### 1.1 ¿Hace falta buscar?

El reproductor pide una pista por su **id de Deezer**, no por un id de YouTube.
`extraction_isolate.dart` decide primero si ya tiene un id de YouTube:

1. Si el id parece un id real de YouTube (11 caracteres base64url y **no**
   puramente numérico — el chequeo numérico existe para que un id de Deezer de
   11 dígitos no se confunda con uno de YouTube), se usa tal cual y **no hay
   búsqueda ninguna**.
2. Si no, se mira `_resolvedMatchCache` (caché **en memoria**, por sesión):
   si esta pista ya se resolvió antes, se reutiliza el vídeo. La caché se
   escribe **solo tras una extracción realmente exitosa**, para que un match
   equivocado no quede fijado el resto de la sesión.
3. Si no hay caché, se busca (§1.2).

### 1.2 La escalera de búsquedas

Se ejecutan en este orden, y **los candidatos se acumulan** entre intentos
(dedup por `videoId`), no se reemplazan. Se corta en cuanto algún candidato
supera el umbral de aceptación:

| # | Query | Cliente Innertube |
| :-- | :--- | :--- |
| 1 | `artista título` | `WEB` |
| 2 | `artista título official audio` | `WEB` |
| 3 | `artista título` | `ANDROID` |
| 4 | solo el título | `WEB` |

(el artista es solo el **principal**, no la lista de colaboradores separada por
comas; al título se le quitan sufijos de versión tipo "- Remastered 2011").

### 1.3 Dónde entra YouTube Music

Dentro de **cada** uno de esos intentos, la función JS `searchVideos`
(`js_bundle_loader.dart`) prueba tres cosas en cascada:

1. **`yt.search(query, {type: 'video'})`** — la búsqueda de vídeos de YouTube.
   Es la fuente principal y casi siempre la única que hace falta.
2. **Búsqueda cruda vía `yt.actions.execute('/search')`** — solo si (1) lanzó
   una excepción de parseo (pasa con el cliente `ANDROID`: su parser falla con
   "Cannot cast SearchMobileHeader", y este camino crudo **pierde la
   duración**).
3. **`yt.music.search(query, {type: 'song'})` — YouTube Music.** Se consulta
   **solo si los pasos anteriores juntaron menos de 8 candidatos**, y sus
   resultados se **añaden** a los que ya hubiera, no los reemplazan.

> **Por qué ese umbral y no siempre:** el caso que lo motivó es un tema de
> nicho que en YouTube solo existe como pista auto-generada de YouTube Music
> (canal `<Artista> - Topic`), mientras la búsqueda de vídeos devuelve 20
> canciones homónimas de otros artistas. Con la condición original
> (`results.length === 0`) nunca se llegaba a mirar donde sí estaba la
> canción. El umbral de 8 es un compromiso: una consulta de red extra por
> pista tiene coste, y para temas populares la búsqueda de vídeos ya trae el
> master correcto.

**Consecuencia importante y contraintuitiva:** para una canción **popular**,
YouTube Music **no se consulta nunca**, porque la búsqueda de vídeos ya
devuelve ≥8 resultados. Ahí toda la responsabilidad de no elegir un karaoke o
un re-subido recae en el ranking de `yt_search_matcher.dart` (§2).

### 1.4 De dónde sale el audio

De YouTube, siempre, vía `youtubei.js` en QuickJS con la jerarquía de clientes
`['ANDROID', 'ANDROID_VR', 'WEB']` (Pitfall #18). Un resultado que vino de
YouTube Music es igualmente un `videoId` de YouTube: `music.youtube.com` y
`youtube.com` comparten el mismo espacio de ids. **No existe un "modo YouTube
Music" de reproducción.**

---

## 2. Cómo se elige el candidato (`YtSearchMatcher`)

Filtros duros (descalifican, no restan puntos):

- **Solapamiento de título** ≥ 50% (≥ 70% en el pase relajado).
- **Términos indeseados** en título o canal (`karaoke`, `instrumental`,
  `cover`, `live`, `backing track`, `no vocals`…). Es simétrico: si el título
  *esperado* ya trae el término (la pista de Deezer es un directo), ese término
  deja de descalificar.
- **Corroboración**: duración en rango (±20 s) **o** artista confirmado.

Bonificaciones:

| Señal | Puntos |
| :--- | ---: |
| Solapamiento de título | `overlap × 0.6` (máx. 60) |
| Duración exacta (≤3 s) | +100 |
| **Fuente autorizada** (canal `- Topic`, VEVO, o resultado de YouTube Music) | **+120** |
| Artista confirmado (en el canal o en el título) | +50 |
| Términos de calidad en el título (`official`, `audio`, `lyrics`…) | **+30 en total** |
| Posición en los resultados de YouTube | +10 … +1 |

### 2.1 Por qué "fuente autorizada" vale más que nada (caso "Ladders")

Reportado en QA: reproduciendo **"Ladders – Mac Miller"** sonó una pista
instrumental (`https://www.youtube.com/watch?v=zaas98hALf4`).

El dato que decide el diagnóstico: ese vídeo **se titula literalmente
"Ladders - Mac Miller (Official Audio)"**. No dice "instrumental", ni
"karaoke", ni "cover" en ninguna parte. Es decir, **ninguna lista de términos
indeseados podía atraparlo** — la hipótesis natural ("faltan penalizaciones por
palabra clave") es falsa para este caso.

Con los pesos anteriores el impostor ganaba de forma sistemática:

| Señal | Re-subida `zaas98hALf4` | Master `Mac Miller - Topic` |
| :--- | ---: | ---: |
| Título | +60 | +60 |
| Duración exacta | +100 | +100 |
| `official` (+30) y `audio` (+30), sumados por separado | **+60** | 0 |
| Canal autorizado | 0 | **+30** |
| Artista confirmado | +50 | +50 |
| Posición | +10 | +9 |
| **Total** | **280** | **249** |

Escribir dos palabras de marketing en el título valía el doble que ser el
master entregado por el sello. Los dos cambios que lo corrigen:

1. Los términos de calidad del título suman **un solo bonus acotado** (+30 en
   total, no +30 por término): es texto libre que cualquiera puede escribir.
2. La señal de canal sube a **+120**, por encima incluso de la duración
   exacta, porque es la única evidencia que un re-subidor **no puede
   falsificar**. Un canal `- Topic` lo genera YouTube automáticamente a partir
   del master que entrega el sello.

Además, un resultado que viene del shelf de canciones de YouTube Music se marca
con `source: 'ytmusic'` en `js_bundle_loader.dart` y cuenta como fuente
autorizada: ese catálogo son masters oficiales por construcción, y ahí el autor
llega como nombre de artista, **sin** el sufijo `- Topic`, así que sin la marca
sería indistinguible de una re-subida.

Cobertura: `test/core/extraction/yt_search_matcher_test.dart`, grupo
*Regresión "Ladders"*. Verificado que los tres tests fallan con los pesos
anteriores.

### 2.2 Qué sigue sin cubrir

Si el vídeo equivocado **no** está en un canal autorizado y el correcto
**tampoco** (por ejemplo, la canción no tiene `- Topic` y ambas son
re-subidas), las señales restantes vuelven a ser título + duración + posición,
y un instrumental de la misma duración sigue siendo indistinguible por
metadatos. La vía real para ese caso sería consultar YouTube Music siempre (no
solo con <8 candidatos), a costa de una petición de red extra por pista.

---

## 3. Portadas: por qué "Mr. Brightside" salía con la portada de "Nu Rock"

Reportado como menor en la misma ronda. **Verificado contra la API en vivo: no
es un bug del código de Syncora.**

`GET /search?q=Mr. Brightside The Killers` devuelve como **primer** resultado, y
con diferencia el de mayor `rank` (905.448 contra 449.168 del siguiente):

```
953097 | Mr. Brightside | rank=905448 | album= Nu Rock (107198) | artist= The Killers
```

La versión de *Hot Fuss* (el álbum original) **no aparece en los primeros ocho
resultados**. Y no es una peculiaridad de `/search`:

- `GET /artist/897/top` (top de The Killers) devuelve **la misma** pista 953097,
  también atribuida a "Nu Rock".
- `GET /2.0/track/isrc:USIR20400274` (búsqueda por el ISRC de la grabación)
  devuelve **la misma** pista 953097, también con "Nu Rock".

O sea: para Deezer, la entrada canónica de esa grabación **cuelga de la
recopilación**. Nuestro ranking no la eligió mal; es la única que Deezer ofrece
como principal.

**Por qué no se puede detectar y corregir barato:** el payload de `/search` no
trae ninguna señal de recopilación. El objeto `album` embebido solo tiene
`id`, `title` y las URLs de portada — ni `record_type` ni el artista del álbum.
Hay que pedir `GET /album/107198` aparte para ver que su artista es
`id: 5080, name: "Varios Artistas"`. Y ojo: ahí `record_type` vale `"album"`,
**no** `"compilation"`, así que ese campo tampoco sirve como detector.

Corregirlo de verdad exigiría, por cada pista: una petición para saber si su
álbum es una recopilación, y varias más para localizar el álbum original del
artista que contiene esa grabación. Contra una API con un límite de 50
peticiones cada 5 segundos por IP (Pitfall #4), y para cambiar una miniatura.
**Decisión: no se implementa**; queda documentado para que no se vuelva a
investigar desde cero. Si alguna vez se hace, el detector correcto es
`album.artist.id == 5080` (el "Varios Artistas" canónico de Deezer), nunca
`record_type`.
