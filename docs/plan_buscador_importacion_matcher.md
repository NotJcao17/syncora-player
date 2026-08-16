# Plan de implementación — Buscador, Importación y Matcher YouTube

> Documento de planificación. Redactado tras una sesión de análisis y pruebas en vivo contra la API
> de Deezer. Todos los hallazgos citados aquí fueron verificados empíricamente, no inferidos.

## Contexto y diagnóstico

Se identificaron **tres frentes** con problemas, no dos como se pensaba al inicio:

1. **Buscador Deezer** — resultados populares enterrados o ausentes
2. **Importación CSV** — ~1/3 de fallos al importar
3. **Matcher Deezer→YouTube** — descubierto durante la sesión; peor de lo esperado

### Hallazgos verificados contra la API

| Hallazgo | Evidencia |
|---|---|
| `/search` sin `limit` devuelve solo **25** resultados; el máximo real es **100** | Confirmado; `limit=200` sigue devolviendo 100 |
| **Bruno Mars** aparece en la posición ~92 de 100 para la query `bruno` | Nunca entra en los 25 que trae hoy la app |
| Los artistas **no se ordenan** por popularidad | Adele (15.4M fans) queda tras "Adele & The Chandeliers" (418 fans) |
| `/search` **no devuelve el array `contributors`** | Solo `/track/{id}` y `/artist/{id}/top` lo traen |
| El CSV de Spotify usa la columna **`Artist Name(s)`** | El parser solo reconoce `artist` / `artist name` exactos → toda fila se importa **sin artista** |
| La sintaxis avanzada `artist:"X" track:"Y"` acertó **10/10** filas del CSV | Texto plano falló 2/10 (trajo versiones Live/Acústica) |
| La sintaxis avanzada es **frágil ante variantes de escritura** | `"Ed Sheran"` (typo) → 0 resultados; `"KAROLG"` → 0 resultados |
| `artist:"A" artist:"B"` **no hace AND** | Devuelve 200 resultados de basura; el texto plano `"A B"` sí encontró la colaboración |
| **No existe endpoint batch** para varios tracks | `/tracks?ids=`, `/track/1,2`, `/tracks/1` → todos `InvalidQueryException` |
| `pickBest` **nunca compara el título** | El parámetro `title` es código muerto en `yt_search_matcher.dart:58-140` |
| Un nombre de artista con más palabras **no es menos relevante** — a diferencia de un título | Con la fórmula de título aplicada a artistas, "Bruno" (12 mil fans, match exacto) le ganaba a "Bruno Mars" (12.7M fans) por el término de precisión. Fix: `artistTextScore` separado, sin ese término (ver Fase A, implementado) |
| Un artista puede matchear por nombre exacto en `/search/artist` **sin tener ninguna canción real** en los resultados de esa búsqueda | "DJ Despacito" (4137 fans) pasaba el filtro de score para la query "despacito" pero no tiene ninguna pista en el pool — cuenta de DJ/novedad incluida por relevancia difusa de Deezer, no el objetivo real. Fix: gate de presencia en el pool de tracks antes de aceptar un "artista dominante" (implementado) |
| Para títulos muy cubiertos/genéricos, **ni siquiera el texto plano de Deezer incluye la versión canónica** en el pool de 100 | "someone like you adele", "adele someone like you" y hasta "someone like you" solos → la Adele real **no aparece en ningún caso** dentro de 100 resultados. Solo `artist:"Adele" track:"Someone Like You"` (sintaxis avanzada) la encuentra, en la posición 1. Ningún re-ranking en cliente puede rescatar un candidato que Deezer nunca devolvió — límite real del re-ranking en cliente, documentado como test de regresión, no "arreglado" |

### Dos casos de "colaboración faltante" con causas distintas

**Caso "3 A.M." (Jesse & Joy + Gente De Zona) — bug de visualización nuestro, no de Deezer.**
El track `id=390959001` (rank 540454) **ya es la colaboración** (`contributors: Jesse & Joy + Gente De Zona`)
y es el más popular. Se percibe como "la versión solista menos famosa" porque `/search` solo devuelve
el artista principal y la app muestra "Jesse & Joy" a secas.

**Caso "Guess" (Charli xcx) — hueco real del índice de Deezer.**
La versión solista (ISRC `USAT22403715`, ids `3038020721` / `2837358742`) **existe pero no está en el
índice de búsqueda bajo ninguna query**, ni con sintaxis avanzada (`total=1`). Deezer colapsa variantes
de título. Solo alcanzable vía `/album/{id}/tracks`.

**Frecuencia del patrón "Guess":** se probaron 10 pares solista/colaboración conocidos
(Stay, Señorita, Thinking Out Loud, I Don't Care, Un Día, Con Calma, Mi Gente, Take Care, Boyfriend,
Good Things Fall Apart). **En los 10 apareció normalmente.** Se concluye que es una rareza del catálogo
de *BRAT* (relanzado con múltiples álbumes de título casi idéntico), **no un patrón sistemático**.
→ No justifica construir un crawler automático. Se relega a una acción manual de baja prioridad.

### Por qué apps como Lyra/OpenTune no tienen este problema

Son **clientes de YouTube Music directo** — buscan y reproducen del mismo catálogo, un solo salto.
Syncora tiene dos saltos (Deezer para metadata/portadas/BD, YouTube para audio) y ese puente es donde
viven casi todos estos bugs. Es una diferencia de arquitectura, no de calidad de algoritmo.
Cambiar de proveedor no es viable: Deezer es la clave primaria de toda la base de datos.

---

## Decisiones de diseño tomadas

### 1. Ranking: score **mezclado**, no tiers estrictos

Los tiers lexicográficos (texto manda siempre) se **descartaron** tras probarlos: para `uptown`
devolvían "Bex – Uptown" y "Drake – Uptown" por encima de *Uptown Funk*; para `adele` devolvían
"Caio Ocean – Adele" y "Les Youles – Adele" antes que Adele.

La fórmula es **texto + popularidad en la misma escala**, de modo que la popularidad pueda rescatar un
match de texto ligeramente peor, pero nunca uno irrelevante:

```
uptown  →  1. Mark Ronson - Uptown Funk   (texto 80 + pop 98 = 178)
           2. Billy Joel  - Uptown Girl    (texto 80 + pop 84 = 164)
           4. Bex         - Uptown         (texto 100 + pop 41 = 141)
```

Validado en 15 queries: **12/12 casos evaluables acertaron**.

**Dos bugs pendientes de corregir en la fórmula prototipo:**
- **Bug A — apóstrofes.** `"god's"` → `"god s"` al convertir `'` en espacio, y el query `"gods"` nunca
  matchea. *Fix: eliminar apóstrofes, no convertirlos en espacio.*
- **Bug B — covers ganan al original.** `"someone like you adele"` → gana un cover de Glee Cast
  (*"Rumour Has It / Someone Like You (Cover of Adele)"*) porque contiene todas las palabras del query;
  la Adele real ni aparece en el top 5. *Fix: similitud tipo Jaccard/solapamiento ponderado en vez de
  conteo simple de "contiene"; penalizar exceso de tokens no pedidos en el título.*

### 2. Señal de popularidad del **artista** (`nb_fan`), no solo del track

El score mezclado por sí solo no arregla `adele` del todo (deja arriba a "Adèle Castillon", rank 995689).
La pieza faltante es `nb_fan`: Adele tiene 15.4M, Adèle Castillon muchos menos.

Sale **gratis** en la pestaña "Todo" (ya se pide `/search/artist` en paralelo). El bonus debe ir
**escalado por fans**, para que un artista de 15M mueva la aguja y uno de 500 no — así no rompe `uptown`,
donde no hay artista dominante.

### 3. Enriquecimiento de colaboradores: **proactivo dirigido**

No existe endpoint batch, así que cada enriquecimiento cuesta 1 petición a `/track/{id}`.

En vez de enriquecer "los primeros N", enriquecer **solo los títulos ambiguos** (los que se repiten
dentro del mismo resultado, normalizando sufijos como `(feat…)`, `(Remix)`, `(Live)`). Es exactamente
el caso donde el usuario no puede distinguir una colaboración de una versión solista.

Costo medido en 15 búsquedas: **promedio 1.8 peticiones**, máximo observado 7 (`despacito`).
6 de 15 búsquedas costaron **0**.

Presupuesto por búsqueda asentada: `3 (base) + 1 (top tracks, condicional) + 1.8 ≈ 5.8` promedio,
~11 peor caso, contra un límite de **45 req/5s** → ~7.7 búsquedas asentadas por cada 5s.

Protecciones: el `RateLimiter` **encola, no falla** (pasarse = lentitud, nunca error); el
enriquecimiento se **aborta si cambia la query**; **tope duro de 8** peticiones por búsqueda.

### 4. Mantener resultados mientras se teclea

Los problemas son de *ranking e índice*, no de timing. El debounce de 500ms ya garantiza que solo se
dispara sobre la query final. Quitar la búsqueda incremental no mejoraría ni un resultado.

### 5. Cadena de fallback para resolución programática

La sintaxis avanzada es precisa pero frágil ante typos y variantes. Para importación / "agregar a
playlist" / búsqueda profunda:

```
artist:"X" track:"Y"   →   si 0 resultados:  texto plano "X Y" + validación por duración
                       →   si 0 resultados:  solo título
```

Para el buscador libre (usuario tecleando) **no** se usa esta sintaxis, sino el score mezclado sobre el
pool de 100.

### 6. Tolerancia de duración, nunca coincidencia exacta

Las duraciones de Spotify y Deezer difieren (masterizaciones, fades, redondeos). Se reutiliza la escala
ya calibrada en `yt_search_matcher.dart:86-97`: `≤3s` alta confianza, `≤10s` media, `≤20s` baja,
`>30s` penaliza fuerte.

---

## Estrategia de pruebas del algoritmo de ranking (Fase A)

La validación hecha durante el análisis (15 queries, script Node ad-hoc contra la API en vivo) fue
exploratoria — sirvió para decidir el enfoque (score mezclado vs. tiers), pero **no es una suite de
regresión reproducible**: el `rank` de Deezer cambia con el tiempo (popularidad real de las canciones),
así que una prueba que compare contra la API en vivo puede empezar a fallar en unos meses sin que el
código tenga ningún bug.

**Enfoque para la implementación real:**

1. **Fixtures grabadas, no llamadas en vivo en los tests automatizados.** Capturar un snapshot JSON de
   respuestas reales de `/search` para un set de queries representativas (las que ya se probaron en esta
   sesión + las nuevas de abajo) y guardarlas como fixtures en `test/fixtures/deezer_search/`. El módulo
   de ranking (`search_ranking.dart`) se testea puramente offline contra esas fixtures: determinista,
   repetible, no depende de que Deezer no haya cambiado nada.
2. **Ampliar el set de casos** más allá de los 15 ya probados, cubriendo categorías aún sin cobertura:
   - Español con tildes/ñ (`canción`, `José José`, `Maná`)
   - Nombres de artista de una sola palabra que también son palabras comunes (`Queen`, `Eagles`,
     `Chicago`, `Kiss`, `Train`)
   - Títulos muy cortos o genéricos (`1`, `Yes`, `No`, `Home`)
   - Consultas mixtas artista+título en distinto orden (`"Perfect Ed Sheeran"` vs. `"Ed Sheeran Perfect"`)
   - Artistas con muy pocos fans pero coincidencia exacta de nombre (para confirmar que no se cuelan)
   - Colaboraciones con 3+ artistas
3. **Aserciones sobre orden relativo, no sobre scores absolutos** — igual que se señaló para el matcher
   de YouTube (evitar el patrón `expect(score, greaterThan(100))` de número mágico). Verificar
   "X debe estar antes que Y", no un valor exacto.
4. **Antes de cerrar la Fase A:** re-ejecutar el set completo y confirmar que los dos bugs conocidos
   (apóstrofes, covers ganando al original) quedaron resueltos, sin regresionar los 12 casos que ya
   funcionaban.
5. **Mantenimiento:** cuando aparezca un caso real que falle en producción, se agrega su fixture al set
   — la suite crece con el tiempo en vez de quedar fija en los 15 casos iniciales.

Este mismo principio (fixtures grabadas + aserciones relativas) aplica también a los tests nuevos de la
Fase C (matcher YouTube), que además necesita datos de candidatos de YouTube simulados, no solo de Deezer.

---

## Fases de implementación

Orden acordado: **Fase 0 → A (buscador) → B (importación) → C (matcher YouTube)**.
Las fases A y B son cambios acotados; C es una recalibración que conviene hacer con calma y tests nuevos.

---

### Fase 0 — Migración de BD para colaboradores (prerequisito de A y B)

`PlaylistTracks` y `DownloadedTracks` guardan `artistName` como un solo `TEXT` aplanado y `artistId`
como un solo `int`. `SyncoraTrack.artists` sí soporta lista en memoria, pero **nunca se persiste**.

- [x] Añadir columna `contributorsJson` (TEXT, nullable) a `PlaylistTracks` y `DownloadedTracks`
      en `lib/data/local_db/syncora_database.dart`
- [x] `schemaVersion` 3 → 4; migración **aditiva** con `m.addColumn` (filas viejas quedan en `NULL`)
- [x] Mantener `artistName` intacto para no romper lo que ya funciona (lecturas, sync, UI actual)
- [x] Serializar/deserializar en `PlaylistDao.addTrackToPlaylist` y `DownloadedTrackDao` — helpers
      `SyncoraArtistRef.encodeList`/`decodeList` en `player_models.dart`
- [x] Al agregar a playlist / dar like / descargar: 1 petición puntual a `/track/{id}` para obtener
      `contributors`, vía `lib/core/utils/contributor_resolver.dart` (no en el listado, solo al guardar).
      Cubre los 4 puntos de entrada: `track_tile.dart` (like, agregar a playlist),
      `playlist_detail_screen.dart` (agregar desde búsqueda dentro de la playlist),
      `library_screen.dart` (importación CSV), `download_service.dart` (descarga)
- [x] Verificar que `SyncoraTrack.artists` sobreviva el round-trip BD → modelo → UI —
      `playlist_detail_screen.dart` y `downloads_screen.dart` decodifican `contributorsJson` primero,
      con fallback al parseo por comas para filas antiguas sin este dato
- [x] Tests: round-trip de `encodeList`/`decodeList` (incluye JSON corrupto/nulo/vacío) en
      `player_models_test.dart`; persistencia de `contributorsJson` en `playlist_dao_test.dart` y
      `downloaded_track_dao_test.dart`. Suite completa: 77 tests, 0 fallos. `flutter analyze` limpio.

> Sin datos de usuarios en producción todavía, así que el riesgo de migración es bajo.

---

### Fase A — Buscador Deezer

Archivos: `lib/data/apis/deezer_api.dart`, `lib/features/search/search_provider.dart`,
`lib/features/search/screens/search_screen.dart`, + nuevo módulo de ranking.

- [x] **A1.** `limit=100` añadido a las 4 llamadas de búsqueda (`/search`, `/search/artist`,
      `/search/album`, y la rama de tipo único). No añade peticiones, es la misma llamada HTTP con
      más resultados.
- [x] **A2.** Nuevo módulo `lib/features/search/search_ranking.dart`, puro y testeable de forma
      aislada:
  - `normalize`: **elimina** apóstrofes (Bug A) y colapsa diacríticos
  - `textScore`: similitud recall+precisión ponderada (Bug B) — para TÍTULOS
  - `artistTextScore`: función **separada** para nombres de artista (ver hallazgo abajo)
  - `popScoreFromRank` (0..1M → 0..100), `fanBonus` (escala logarítmica, tope 40)
- [x] **A3.** Artistas ordenados por `artistTextScore + fanBonus` combinados (antes: sin ordenar,
      solo filtro `nb_fan >= 1000` en `deezer_api.dart:101`).
      **Hallazgo durante la implementación (validado con fixtures reales):** usar la misma fórmula de
      `textScore` (pensada para títulos) en nombres de artista penalizaba a cualquier artista real con
      nombre de 2+ palabras — "Bruno" (12 mil fans, match exacto) le ganaba a "Bruno Mars" (12.7M fans)
      porque el término de precisión castigaba la palabra "Mars" de más. Fix: `artistTextScore` sin ese
      término (un nombre de artista con más palabras no es "menos relevante", a diferencia de un título).
- [x] **A4.** Pestaña "Todo": si el artista dominante no aparece en el top 5 de canciones, inyectar
      `getArtistTopTracks` (+1 petición condicional) y re-rankear.
      **Hallazgo adicional:** se necesitó un segundo gate — un artista puede matchear por nombre exacto
      en `/search/artist` sin tener ninguna canción real en los resultados de esa búsqueda (ej. "DJ
      Despacito" para la query "despacito"). `findDominantArtist` ahora exige que el candidato tenga al
      menos una pista en el pool ya traído, si no, se descarta como dominante (evita backfill y bonus
      espurios).
- [x] **A5.** Enriquecimiento dirigido de títulos ambiguos: `SearchRanking.baseTitle` agrupa por
      título-base (quita `(feat...)`, `featuring...` sin paréntesis, sufijos `- Remix/Live/...`) +
      artista entre los primeros 20 resultados; para grupos con >1 miembro, pide `/track/{id}` (tope 8)
      y reemplaza el track con `DeezerTrack.withContributors`. No hace falta lógica de "abortar si
      cambia la query": el `_searchCache` guarda el resultado ya enriquecido, y `search_provider.dart`
      ya descarta resultados de queries obsoletas (`if (state.query.trim() != query) return;`).
- [x] **A6.** Caché LRU extendida a `getArtistTopTracks` y a `getTrack` (`/track/{id}`) — antes solo
      cacheaba búsquedas. Refactorizado a una clase `_LruCache<K,V>` genérica reusada 3 veces.
- [x] **A7.** Suite de regresión con fixtures grabadas: 24 queries capturadas en
      `test/fixtures/deezer_search/` (los 15 casos ya probados + artistas-palabra-común como
      Queen/Eagles/Chicago, español con tildes como José José/Maná, y consultas en distinto orden de
      palabras). 27 tests en `test/features/search/search_ranking_test.dart`, todos pasando.
      **Hallazgo importante documentado como test, no "arreglado":** para "someone like you adele", la
      Adele real **no aparece ni en el pool de 100** resultados de Deezer — confirmado también con
      `"someone like you"` y `"adele someone like you"` en texto plano contra la API en vivo. Solo
      `artist:"Adele" track:"Someone Like You"` (sintaxis avanzada) la encuentra. Es un límite del índice
      de Deezer, no algo que el ranking en cliente pueda resolver — la vía real es la sintaxis avanzada
      ya usada en Importación (Fase B) y Búsqueda Profunda (Fase D).

**Pesos calibrados y validados contra 24 queries reales** (no solo las 15 originales). Los dos hallazgos
adicionales (artistTextScore, gate de presencia en pool) salieron precisamente de correr la suite de
regresión contra datos reales antes de darla por buena — confirma que valía la pena la ronda extra de
pruebas.

### Fase A — hallazgos de pruebas manuales post-implementación (ronda 2)

Encontrados probando la app en vivo (no en la sesión de diseño original), cada uno confirmado contra la
API de Deezer real antes de tocar código. Suite ampliada a 26 fixtures / 33 tests.

- [x] **A8. Match por prefijo, no igualdad exacta de tokens.** `artistTextScore`/`textScore` comparaban
      tokens completos: una query a medio teclear ("bruno m", "arian") nunca matcheaba el token completo
      del nombre real ("mars", "ariana") y el artista correcto quedaba fuera de `minRelevance` —
      confirmado que Deezer sí lo devuelve, era descarte nuestro. Fix: `_covers(query, target) =>
      target.startsWith(query)` en vez de igualdad — estrictamente más permisivo, no rompe ningún caso
      de los 24 anteriores (recall solo puede subir, nunca bajar).
- [x] **A9. Filtro de presencia en pool para artistas "novedad".** `SearchRanking.filterArtistsWithPresence`:
      en la pestaña "Todo" (donde el pool de tracks ya viene gratis), descarta artistas que matchean por
      nombre pero no tienen ninguna canción real en el pool (caso real: "DJ Despacito", 4137 fans, cero
      canciones en el pool de "despacito"). Se exceptúan artistas con ≥50k fans (`popularArtistMinFans`)
      para no penalizar a uno realmente famoso por mala suerte puntual del pool.
- [x] **A10. Toggle "Popular" (UI, `search_provider.dart` + `search_screen.dart`).** Activado por defecto.
      Filtro 100% en cliente sobre datos ya traídos (`rank` de tracks, `nb_fan` de artistas) — cero
      peticiones extra. Umbrales en `search_ranking.dart`: `popularTrackMinScore = 30` (rank ≥ ~300k),
      `popularArtistMinFans = 50000`. Reemplaza el corte fijo de 5 artistas en "Todo" por uno dinámico
      (0-5, los que realmente pasan el umbral); la pestaña "Artistas" dedicada sube el tope a 40. El
      mini-buscador de "agregar canciones" en playlists (`playlist_detail_screen.dart`) reusa el mismo
      `deezerApi.search(type: track)` y aplica este mismo filtro Popular siempre, sin exponer el toggle.
- [x] **A11. Enriquecimiento de colaboradores (A5) ampliado y paralelizado.** A5 original solo enriquecía
      cuando Deezer repetía el mismo título+artista en el pool (señal de ambigüedad) — funcionaba por
      casualidad para "Despacito"/"My Universe" (sí tienen duplicado) pero nunca para "Guess featuring
      billie eilish", "Uptown Funk" o "Un Día (One Day)" (sin duplicado, sin pista en el pool). Fix: los
      primeros 5 tracks del ranking final (`_alwaysEnrichTop`) SIEMPRE entran como candidatos a
      enriquecer, no solo los ambiguos — mismo tope de 8 peticiones ya presupuestado, solo mejor
      priorizado. Las peticiones van en paralelo (`Future.wait`), no secuenciales — el bucle secuencial
      original hacía perceptible el costo en UI (~3s para 5 peticiones en serie).
      **Descartado a propósito:** extraer el colaborador directamente del texto del título (ej. "Uptown
      Funk (feat. Bruno Mars)", gratis, sin request) — el nombre extraído así no tiene `artistId` real de
      Deezer y sale como texto no clickeable en la UI, inconsistente con el resto. Se prefiere pagar la
      petición y tener siempre un ID real.
- [x] **A12. Fixtures nuevas:** `bruno_m.json`, `arian.json` (para A8). Total 26 fixtures,
      `test/features/search/search_ranking_test.dart` con 33 tests. `test/fixtures/deezer_search/` pesa
      ~7MB / ~124k líneas — trivial para git, se recomienda comitear tal cual (es el diseño intencional
      de la suite: fixtures grabadas > llamadas en vivo en tests).
- [x] **A13. Dedup de `contributors` por id.** Tras A11 (enriquecimiento ampliado), apareció "Mark
      Ronson, Bruno Mars, Bruno Mars" en UI. Causa confirmada contra la API en vivo: `/track/{id}` de
      Deezer devuelve al mismo colaborador dos veces con roles distintos (`"Main"` y `"Featured"`, mismo
      id — ej. Bruno Mars en `track/92734438`) — dato real de Deezer, no bug de diseño nuestro.
      `DeezerTrack.fromJson` ahora deduplica el array `contributors` por id (o por nombre si el id viene
      en 0). Tests en `test/data/deezer_track_test.dart`.

---

### Fase B — Importación CSV

Archivo: `lib/features/library/import_export/playlist_import_export_service.dart`

- [x] **B1.** Detección de columnas flexible — reconocer `Artist Name(s)`, `Track Name`, `Album Name`,
      etc. Hoy la lista de nombres exactos (`playlist_import_export_service.dart:77-85`) falla con el
      export real de Spotify y **toda fila se importa sin artista**. Este es el bug que causa el ~1/3
      de fallos.
      **Implementado:** columna de artista/álbum/duración por `contains('artist'/'album'/'duration')`
      en vez de igualdad exacta (cubre `Artist Name(s)`, `Album Name`, `Duration (ms)` sin abrir falsos
      positivos entre sí, ya que cada columna cae en una sola categoría). `RawImportTrack` ganó el campo
      `durationMs`.
- [x] **B2.** Cadena de fallback avanzada → texto plano → solo título (ver decisión 5), en vez del
      único intento a ciegas que toma `searchRes.tracks.first` sin validar nada.
      **Implementado** en `PlaylistImportExportService._resolveTrack`: intenta
      `artist:"X" track:"Y"` primero, luego texto plano `"X Y"`, luego solo título — cada tier valida
      por duración (B3) antes de aceptar; el último tier no tiene mejor alternativa así que toma el
      candidato más cercano en duración (o el primero si no hay duración conocida).
- [x] **B3.** Validación por duración con tolerancia usando `Duration (ms)` del CSV (ver decisión 6),
      para no quedarse con la versión Live/Acústica/Remix.
      **Implementado:** `_bestByDuration` — tolerancia de 20s para los tiers avanzada/texto-plano
      (dentro del rango "confianza media/baja" de la escala ya calibrada en `yt_search_matcher.dart`);
      sin tolerancia (mejor disponible) en el tier de solo-título, por ser el último recurso.
- [x] **B4.** Separar múltiples artistas por `;` (formato Spotify: `Gente De Zona;Marc Anthony`) y usar
      el primero como artista principal en la query avanzada.
      **Implementado:** `_primaryArtist` toma el primero antes del `;`; `RawImportTrack.artist`
      conserva la cadena completa (se usa tal cual en el reporte de no-matcheados, B6).
- [x] **B5.** Limpiar sufijos `(feat. …)` del título antes de la query avanzada
      (validado: es lo que hizo funcionar `Conqueror` de AURORA).
      **Implementado:** `_queryTitle` (regex `_featSuffix`, cubre `feat.`/`featuring`/`ft.`/`with`,
      con o sin paréntesis/guion previo) — solo se usa para construir la query, `RawImportTrack.title`
      original queda intacto para el reporte.
- [x] **B6.** Reporte de no-matcheados accionable al final de la importación.
      **Implementado** en `library_screen.dart`: lista scrolleable (`ListView.builder`, tope 200px) de
      cada pista no encontrada (`"$artist - $title"`) en el diálogo de fin de importación, en vez de
      solo el conteo.
- [x] **B7.** Tests con `docs/test.csv` como fixture.
      **Implementado** en `test/data/import_export_test.dart`: parseo del fixture real (10 filas, todas
      con artista detectado — confirma el fix de B1), más casos puntuales para `Artist Name(s)` (B1) y
      colaboradores separados por `;` (B4). El fallback con validación por duración (B2/B3) no se testea
      automatizado porque requiere llamadas en vivo a Deezer (fuera del alcance de tests reproducibles,
      igual que el resto del proyecto) — verificado manualmente contra la API real durante el diseño.

---

### Fase C — Matcher Deezer→YouTube

Archivos: `lib/core/extraction/yt_search_matcher.dart`, `lib/core/extraction/extraction_isolate.dart`

Ordenado por impacto en el usuario (canción que suena equivocada o no suena).

- [ ] **C1. Usar `title` en el scoring.** Es el bug de fondo: el parámetro se recibe como requerido y
      **no se usa en ninguna línea** (`yt_search_matcher.dart:58-140`). Hoy cualquier vídeo del mismo
      artista con duración parecida puntúa igual que el correcto. Añadir solapamiento de tokens y
      convertirlo en **requisito de aceptación**, no solo en un sumando.
- [ ] **C2. Acotar el bonus de posición.** `score += (candidates.length - index) * 2`
      (`yt_search_matcher.dart:119`) escala con el tamaño de la lista y no tiene tope: en la ruta de
      fallback (30-60 candidatos) el primero recibe +60 a +120, **más que un match exacto de duración
      (+100)**. Usar algo como `max(0, 10 - index)`, independiente de `N`.
- [ ] **C3. Arreglar el match de artista.** Falla en los dos casos más frecuentes:
  - Canales VEVO van pegados: `"taylorswiftvevo"` no contiene `"taylor swift"`
  - Colaboraciones: `DeezerTrack.fromJson` une **todos** los contributors en un string
    (`deezer_track.dart:51-56`), y esa cadena completa no existe en ningún canal ni título
  - Comparar por artista **individual** (`track.artists`, que ya existe) y por tokens; comparar
    también contra el canal sin espacios
  - Añadir señal de canal **`- Topic`** (masters exactos del sello) y buscar `vevo` en el **canal**,
    no solo en el título (hoy `'vevo'` es casi inerte porque solo se busca en el título)
- [ ] **C4. `_badTerms` condicional al título de Deezer.** Si el título ya contiene "Remix"/"Live"/
      "Instrumental", **todos** los candidatos arrastran el −80 y sube la tasa de `null` →
      `skipToNext()` → la canción no suena. Penalizar solo la **asimetría**. Además:
  - Límites de palabra en vez de `contains` (hoy penaliza "Undercover Martyn", "Chain Reaction",
    "Coverdale", "Trailer Trash")
  - Tope de una penalización (hoy `"Karaoke Cover"` = −160 acumulado)
  - `lyric` y `lyrics` se cuentan **ambos**: un reupload de lyrics obtiene +60, el doble que un
    Official Video con +30
  - `'m/v'` es **código inerte**: `norm()` borra las barras
  - Añadir `live`, `en vivo`, `sped up`, `slowed`, `nightcore`, `8d`, `bass boosted`, `mashup`,
    `full album`, `1 hour`, `tribute`/`tributo`, `ao vivo`
- [ ] **C5. Construcción de la query** (`extraction_isolate.dart:323`): usar artista principal (no la
      lista con comas), quitar sufijos de versión (`- Remastered 2011`), evitar duplicar el artista
      cuando ya está en el título, y recuperar el hint `"official audio"` que tenía el scraper anterior
      y se perdió en la migración. Variante relajada en el segundo intento (hoy reintenta con
      **exactamente la misma query**, así que falla igual).
- [ ] **C6. Guardar top-3 candidatos** y probar el siguiente si la extracción falla con `notFound`
      (vídeo privado/geobloqueado/age gate). Hoy se descarta la lista y la canción se salta en silencio.
      Invalidar `_resolvedMatchCache` en fallo — hoy se escribe **antes** de saber si funciona y
      **nunca se invalida**, así que un match equivocado queda fijado toda la sesión.
- [ ] **C7. Robustez:**
  - Casts inseguros (`raw['durationSec'] as int?`) pueden lanzar y romper el bucle del isolate;
    sin timeout en `extractUrl`, el `Completer` nunca se resuelve → **spinner colgado para siempre**
  - `jsonEncode(query)` para el escapado (hoy escapa comillas pero no barras invertidas)
  - `durationSec == 0` (que produce `?? 0` en `deezer_track.dart:84`) entra al bloque de duración y
    aplica **−50 a todos** los candidatos
  - `norm()` con `\p{L}` Unicode en vez de tabla manual de diacríticos (hoy borra coreano, japonés,
    cirílico; y no cubre `ł`, `ş`, `ß`, `æ`, `ø`)
  - `is11CharYtId` puede confundir un ID numérico de Deezer de 11 dígitos
- [ ] **C8. Umbral final.** `maxScore >= 0` es permisivo y estricto a la vez: acepta cualquier candidato
      sin penalizaciones (el bonus de posición siempre es ≥ +2) y rechaza remixes/directos legítimos.
      Sustituir por **evidencia positiva**: similitud de título suficiente **y** (duración en rango
      **o** artista confirmado).
- [ ] **C9. Tests.** Escenarios sin cobertura hoy: canción equivocada del mismo artista con duración
      idéntica; efecto del tamaño de la lista (el test de karaoke pasa **solo porque `N=1`**; con `N=5`
      el mismo karaoke sería aceptado); canal VEVO concatenado; colaboración `"A, B"`; canal `- Topic`;
      remix/live legítimo; `durationSec` `null` y `0`; falsos positivos de substring; títulos no latinos;
      frontera del umbral.

---

### Fase D — Opcional, baja prioridad

- [ ] **D1. Búsqueda profunda / colaboraciones (2 artistas)** — rediseño del modal hoy deshabilitado
      (`search_screen.dart:100`, `onPressed: null`). Campos: Artista 1 / Artista 2.
      **5 peticiones en 2 tandas paralelas (~1s)** en vez de las ~10 secuenciales actuales:
  1. Resolver ambos artistas en paralelo (2 req)
  2. En paralelo: texto plano `"Artista1 Artista2"` + `/artist/{A}/top?limit=100` +
     `/artist/{B}/top?limit=100` (3 req)
  3. Filtrar los tops por `contributors` cruzando ambos nombres, sin duplicados

  Sin crawl de discografía por defecto. Si los resultados salen escasos, ofrecer un botón explícito
  "buscar más a fondo" que sí lo haga — decisión del usuario, no automática.

- [ ] **D2. "Buscar otras versiones"** — acción manual en el menú de una canción, para casos tipo
      "Guess". Sin campos que llenar: usa artista/título/fecha de la canción abierta. Acotado por
      **cercanía de fecha de lanzamiento** — crawlear solo los ~10-15 álbumes más cercanos, no toda la
      discografía (Charli xcx tiene 50 álbumes).
      Prioridad baja: el patrón no se repitió en 10 pares probados.

---

## Presupuesto de peticiones (referencia)

`RateLimiter` actual: **45 req / 5s** (`deezer_api.dart:19`), bajo el límite real de Deezer de 50/5s por IP.

| Operación | Peticiones |
|---|---|
| Búsqueda en pestaña "Canciones"/"Artistas"/"Álbumes" | 1 |
| Búsqueda en pestaña "Todo" (base) | 3 |
| + top tracks del artista dominante (condicional) | +1 |
| + enriquecimiento dirigido | +1.8 promedio, +8 tope |
| **Total "Todo"** | **~5.8 promedio, ~11 peor caso** |
| Búsqueda profunda (D1) | 5 en 2 tandas |
| Agregar canción a playlist | 1 |

El `RateLimiter` encola en vez de fallar: excederse produce lentitud, nunca errores de API.
