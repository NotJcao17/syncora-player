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

- [x] **C1. Usar `title` en el scoring.** Es el bug de fondo: el parámetro se recibe como requerido y
      **no se usa en ninguna línea** (`yt_search_matcher.dart:58-140`). Hoy cualquier vídeo del mismo
      artista con duración parecida puntúa igual que el correcto. Añadir solapamiento de tokens y
      convertirlo en **requisito de aceptación**, no solo en un sumando.
      **Implementado:** `_titleOverlap` — % de tokens del título esperado (sin el sufijo `feat.`, que
      YouTube casi nunca repite en el título aunque sí sea la canción correcta) presentes en el título
      candidato. Umbral de aceptación: 50% (`_minTitleOverlapPct`), descarta el candidato de plano si no
      lo alcanza, antes de calcular ningún otro puntaje.
- [x] **C2. Acotar el bonus de posición.** `score += (candidates.length - index) * 2`
      (`yt_search_matcher.dart:119`) escala con el tamaño de la lista y no tiene tope: en la ruta de
      fallback (30-60 candidatos) el primero recibe +60 a +120, **más que un match exacto de duración
      (+100)**. Usar algo como `max(0, 10 - index)`, independiente de `N`.
      **Implementado** tal cual. Verificado con fixture sintética: un candidato real en la posición 35 de
      40 le sigue ganando a 34 candidatos irrelevantes en las posiciones 0-34.
- [x] **C3. Arreglar el match de artista.** Falla en los dos casos más frecuentes:
  - Canales VEVO van pegados: `"taylorswiftvevo"` no contiene `"taylor swift"`
  - Colaboraciones: `DeezerTrack.fromJson` une **todos** los contributors en un string
    (`deezer_track.dart:51-56`), y esa cadena completa no existe en ningún canal ni título
  - Comparar por artista **individual** (`track.artists`, que ya existe) y por tokens; comparar
    también contra el canal sin espacios
  - Añadir señal de canal **`- Topic`** (masters exactos del sello) y buscar `vevo` en el **canal**,
    no solo en el título (hoy `'vevo'` es casi inerte porque solo se busca en el título)
      **Implementado:** `_artistConfirmed` separa el campo `artist` por comas y basta con que UNO de los
      colaboradores matchee; compara tanto contra el autor sin espacios (VEVO concatenado) como contra el
      título como frase completa. `vevo`/`topic` se movieron a una lista de "términos de canal" separada
      (`_goodChannelTerms`) evaluada solo contra `author`, no contra `title` (antes estaban mezclados con
      los términos de calidad del título y `vevo` ahí era casi inerte).
- [x] **C4. `_badTerms` condicional al título de Deezer.** Si el título ya contiene "Remix"/"Live"/
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
      **Implementado con un cambio de diseño respecto al plan original:** un término indeseado
      **descalifica el candidato de plano** (no resta -80 puntos). Se detectó escribiendo el test de
      regresión de "Karaoke Cover": con solo -80 y tope de una penalización, la duración exacta (+100) +
      artista confirmado (+50, el título del karaoke suele decir "Artista - Canción") + bonus de posición
      superaban de sobra la única penalización, y el karaoke volvía a aceptarse — exactamente el riesgo
      que describe C9 ("con N=5 el mismo karaoke sería aceptado"), solo que ahora también pasaba con
      N=1. Descalificar en vez de penalizar deja "tope de una sola penalización" resuelto trivialmente
      (no hay puntaje que acumular) y es más robusto ante cualquier combinación de las otras señales.
      Límites de palabra/frase (`_containsPhrase`, con *lookaround*, no `contains`) arreglan los falsos
      positivos y, de paso, el doble conteo de `lyric`/`lyrics` (son palabras distintas tras normalizar,
      ya no ambas via substring). Los términos se normalizan con la misma `norm()` que el texto
      comparado, así que `'m/v'` se convierte en `'m v'` igual que el título candidato, en vez de buscar
      una barra que `norm()` ya eliminó. Términos nuevos añadidos tal cual los pidió el plan.
- [x] **C5. Construcción de la query** (`extraction_isolate.dart:323`): usar artista principal (no la
      lista con comas), quitar sufijos de versión (`- Remastered 2011`), evitar duplicar el artista
      cuando ya está en el título, y recuperar el hint `"official audio"` que tenía el scraper anterior
      y se perdió en la migración. Variante relajada en el segundo intento (hoy reintenta con
      **exactamente la misma query**, así que falla igual).
      **Implementado** tal cual los 5 puntos. La variante relajada del segundo intento es simplemente el
      título limpio solo (sin artista, sin el hint "official audio") — un cambio real de query, no una
      repetición.
- [x] **C6. Guardar top-3 candidatos** y probar el siguiente si la extracción falla con `notFound`
      (vídeo privado/geobloqueado/age gate). Hoy se descarta la lista y la canción se salta en silencio.
      Invalidar `_resolvedMatchCache` en fallo — hoy se escribe **antes** de saber si funciona y
      **nunca se invalida**, así que un match equivocado queda fijado toda la sesión.
      **Implementado:** `YtSearchMatcher.pickTopCandidates` (mismo ranking que `pickBest`, top-3). El
      caché `_resolvedMatchCache` ahora se escribe **después** de una extracción realmente exitosa, no al
      elegir el candidato — si el primero falla con `notFound` se prueba el siguiente de la lista; si
      falla con otro tipo de error (red/rate-limit) se corta ahí, no tiene sentido seguir probando
      candidatos en ese momento.
- [x] **C7. Robustez:**
  - Casts inseguros (`raw['durationSec'] as int?`) pueden lanzar y romper el bucle del isolate;
    sin timeout en `extractUrl`, el `Completer` nunca se resuelve → **spinner colgado para siempre**
  - `jsonEncode(query)` para el escapado (hoy escapa comillas pero no barras invertidas)
  - `durationSec == 0` (que produce `?? 0` en `deezer_track.dart:84`) entra al bloque de duración y
    aplica **−50 a todos** los candidatos
  - `norm()` con `\p{L}` Unicode en vez de tabla manual de diacríticos (hoy borra coreano, japonés,
    cirílico; y no cubre `ł`, `ş`, `ß`, `æ`, `ø`)
  - `is11CharYtId` puede confundir un ID numérico de Deezer de 11 dígitos
      **Estado real al revisar código:** el timeout de `extractUrl`/`extractVideo` **ya existía**
      (`_tryExtractWithClient` con `.timeout(25s)`, `_trySearchWithClient` con `.timeout(20s)`) — no era
      parte de este trabajo, no se tocó. El resto, implementado: cast defensivo vía `as num?`; `norm()`
      reescrito con `\p{L}\p{N}` Unicode (verificado que Dart lo soporta con `unicode: true`, incluidos
      *lookaround* `(?<!...)`/`(?!...)`) + tabla de diacríticos ampliada (incluye `ł`/`ş`/`ß`/`æ`/`ø` y
      más); `jsonEncode` para los tres valores interpolados en el script JS generado (`videoId`, `client`,
      `jsRequestId`/`query`); `durationSec == 0` ahora requiere explícitamente `> 0` en ambos lados antes
      de entrar al bloque de duración; `is11CharYtId` excluye strings puramente numéricos (un id real de
      YouTube en base64url prácticamente nunca sale así, un id de Deezer siempre).
- [x] **C8. Umbral final.** `maxScore >= 0` es permisivo y estricto a la vez: acepta cualquier candidato
      sin penalizaciones (el bonus de posición siempre es ≥ +2) y rechaza remixes/directos legítimos.
      Sustituir por **evidencia positiva**: similitud de título suficiente **y** (duración en rango
      **o** artista confirmado).
      **Implementado** tal cual: título ≥50% de solapamiento (C1) Y (duración dentro de 20s O artista
      confirmado). Sin duración esperada conocida (`null`/`0`), el segundo término solo puede satisfacerse
      con artista confirmado.
- [x] **C9. Tests.** Escenarios sin cobertura hoy: canción equivocada del mismo artista con duración
      idéntica; efecto del tamaño de la lista (el test de karaoke pasa **solo porque `N=1`**; con `N=5`
      el mismo karaoke sería aceptado); canal VEVO concatenado; colaboración `"A, B"`; canal `- Topic`;
      remix/live legítimo; `durationSec` `null` y `0`; falsos positivos de substring; títulos no latinos;
      frontera del umbral.
      **Implementado:** 25 tests nuevos en `test/core/extraction/yt_search_matcher_test.dart` (29 en
      total con los 4 originales), cubriendo cada punto de la lista de arriba — incluida la propia
      trampa de "N=1 vs N=5" para el karaoke, que fue justo la que expuso el bug real descrito en C4
      (ver más arriba: el karaoke se aceptaba con N=5 **y también con N=1** bajo el modelo de -80
      puntos, antes de pasar a descalificación directa). Verificado de forma independiente (no solo el
      reporte del subagente que los escribió): `flutter test` 29/29, `flutter analyze` limpio, y
      revisión manual del diff confirmando que solo se tocó el archivo de test.

---

### Fase C — hallazgo de pruebas manuales post-implementación

Encontrado probando la app en vivo con una canción de nicho ("Sofia Giusti - Antes De Que Salga El
Sol"): al darle play, cargaba un par de segundos, saltaba automáticamente y empezaba a sonar la
siguiente pista de la cola. Al volver a hacer click en la pista original, los logs mostraban una
extracción exitosa (`ub_y5t23VcE`) pero el audio que sonaba era el de otra canción.

- [x] **C10 (no estaba en el checklist original). Condición de carrera en `playCurrent()`.**
      `lib/features/player/syncora_player_controller.dart` no tenía ninguna protección contra llamadas
      solapadas: si el usuario cambia de pista mientras una extracción anterior sigue en curso, la
      extracción vieja, al resolver tarde, pisaba el motor de audio sin verificar si la pista para la
      que fue pedida seguía siendo la activa. Real y arreglado (contador `_playGeneration`, test de
      regresión caso 8) — pero **no era la causa del bug reportado**: al reproducir la pista de nicho
      desde cero (sin cambiar de pista de por medio) el síntoma seguía igual, así que había una segunda
      causa independiente. Ver C11.
- [x] **C11. `completed` de libmpv no distingue fin de pista real de fallo de carga.**
      Causa real del bug reportado ("carga un par de segundos, salta automático, no hay error en los
      logs"). `MediaKitEngine` (Windows) escuchaba `_player.stream.completed` y trataba **cualquier**
      `true` como fin de canción — pero libmpv también emite `completed = true` cuando el stream nunca
      llegó a reproducir nada real (URL firmada vencida/403, respuesta vacía, formato roto): desde su
      punto de vista ambos casos son un EOF. El resultado: un fallo de carga se comportaba exactamente
      igual que una canción terminada normalmente — sin error visible, saltando en silencio a la
      siguiente pista de la cola. Además, `_onLog` (el listener del log nativo de mpv) solo procesaba
      líneas con prefijo `silencedetect`, y solo si Skip Silence estaba activo — **cualquier error real
      de mpv (HTTP, demuxer, códec) se descartaba sin llegar nunca al panel de logs de la app**, por
      eso "en los logs no veo un error" pese a que sí lo había, a nivel nativo.
      **Implementado:**
  - `MediaKitEngine` ahora rastrea si hubo reproducción real (`position > 500ms` o `duration` conocida)
    desde el último `setUrl`/`setLocalSource`. Si `completed` llega sin eso, se trata como fallo de
    carga (`AudioProcessingState.error`), no como fin de pista — no dispara `completionStream`.
  - Nuevo `AudioEngine.logStream`: reenvía líneas de mpv con nivel `fatal`/`error`/`warn` (antes se
    descartaban todas salvo `silencedetect`) al panel de logs de la app. `JustAudioEngine` también lo
    implementa, alimentado desde su `onError` ya existente.
  - `SyncoraPlayerController` se suscribe a `logStream` en `init()` y reacciona a la transición a
    `AudioProcessingState.error` con auto-skip — antes **nada** escuchaba ese estado: en Android
    (`JustAudioEngine`, que sí distinguía error de completed desde antes) el reproductor se quedaba
    trabado sin avanzar; en Windows dependía por completo de que `MediaKitEngine` "mintiera" con
    `completed` para no trabarse.
      Tests de regresión: `test/features/player/syncora_player_controller_test.dart`, caso 9 (fuerza
      `AudioProcessingState.error` y confirma auto-skip en vez de bloqueo). El mecanismo de detección de
      libmpv en sí (`_hadMeaningfulPlayback`) no tiene test automatizado — depende de streams nativos de
      `media_kit`/libmpv que no corren en el sandbox de `flutter test` en Windows (mismo motivo que
      `multi_song_extraction_test.dart`); queda pendiente de una próxima prueba manual con la canción de
      nicho para confirmar en vivo, ahora con logs reales de mpv disponibles si algo sigue sin sonar.

- [x] **C12. Regresión introducida por C1/C5/C8: temas de nicho imposibles de reproducir.**
      Causa real del bug (C10 y C11 eran problemas reales pero no eran *este*). Diagnóstico a partir
      de los logs: al reproducir "Sofia Giusti - Antes De Que Salga El Sol" aparecía una tercera
      búsqueda con el nombre de **otra** canción ("Stefano Vieni - Antes de Que Salga el Sol", la
      siguiente de la cola) y jamás un `extractVideo` para la pista pedida — prueba de que la
      extracción devolvió `notFound` y el auto-skip ya había avanzado. Tres defectos combinados,
      todos introducidos en Fase C:
  - **Escalera de queries (C5) mal escalonada.** Los dos intentos eran `"artista título official
    audio"` y `"título"` pelado. El primero, con el hint, estrecha tanto que para un tema de nicho
    devolvió 2 resultados; el segundo **pierde al artista**, y para un título genérico en español
    devuelve sobre todo canciones homónimas de otros artistas (19 candidatos, ninguno el correcto).
  - **Los candidatos se reemplazaban entre intentos**, no se acumulaban: lo que trajo el primer
    intento se tiraba al pasar al segundo, aunque el vídeo correcto estuviera ahí.
  - **El umbral de C8 no tenía degradación.** Si nada pasaba (título ≥50% Y (duración en rango O
    artista confirmado)) → `notFound` → auto-skip. Antes de Fase C el umbral era `maxScore >= 0`,
    que aceptaba casi cualquier cosa: por eso estos temas **sí** sonaban antes. Un upload de nicho
    típico no confirma nada — el canal no lleva el nombre del artista y la búsqueda no siempre trae
    duración (`extractVideoCandidatesFromRaw` la deja en `null` si falta `lengthText`).
      **Implementado:**
  - Escalera de 3 queries de más específica a más laxa: `artista título official audio` → `artista
    título` (sin hint, **conservando** el artista) → `título` solo, como último recurso.
  - Los candidatos se **acumulan** en un pool deduplicado por `videoId` a lo largo de los intentos;
    el ranking siempre ve la unión de todo lo encontrado, y se corta en cuanto algo pasa el umbral.
  - Pase **relajado** de último recurso (`YtSearchMatcher.pickTopCandidates(relaxed: true)`): exige
    **más** título (70% en vez de 50%) a cambio de no exigir corroboración de duración ni artista —
    cuando no hay corroboración posible, el título debe cargar solo con toda la evidencia. Los
    términos indeseados **siguen descalificando** igual que en el pase estricto: relajar no puede
    llegar al punto de reproducir un karaoke. La alternativa real a este pase no era "sonar la
    canción correcta" sino "no sonar en absoluto".
  - Log explícito cuando se usa el pase relajado y cuando ni así hay candidato aceptable (antes el
    fallo era completamente silencioso, que es justo por qué costó tanto diagnosticarlo).
      Tests: 6 casos nuevos en `test/core/extraction/yt_search_matcher_test.dart` reproduciendo el
      caso real (estricto rechaza / relajado acepta / relajado sigue rechazando karaokes / relajado
      exige más título / el relajado sigue prefiriendo artista confirmado).

- [x] **C13. El pase relajado de C12 elegía mal: hacía falta acotar de dónde salen sus candidatos.**
      Tras C12 la pista de nicho ya no se saltaba, pero sonaba **otra canción**: un tema homónimo de
      Nacha Pop (220s) en vez del pedido (~166s). Dos defectos del pase relajado, ambos por no
      distinguir de qué búsqueda venía cada candidato:
  - **Mezclaba los resultados de la query de solo-título con los demás.** Esa query existe para
    ensanchar el pool del pase *estricto*, donde el artista o la duración protegen de un falso
    positivo. En el relajado no hay nada que proteja, así que meter ahí 20 resultados de un título
    genérico es exactamente cómo acaba ganando un homónimo. Se estaba tirando la señal más valiosa
    disponible: **que YouTube devolvió ese vídeo para una búsqueda que incluía al artista**.
  - **Ignoraba la duración por completo.** "No exigir corroboración por duración" (porque a menudo
    la búsqueda ni la trae) se había implementado como "ignorar la duración incluso cuando se
    conoce", y un desfase de 54s es evidencia de sobra de que es otra canción.
      **Implementado:**
  - Los resultados se guardan además por lotes, marcando qué queries llevaban el nombre del artista.
    El pase relajado recorre **solo esos lotes**, del más específico al menos, y se queda con el
    primero que dé algo. El pase estricto sigue viendo el pool completo (incluida la query de
    solo-título), porque ahí la corroboración lo hace seguro.
  - Guarda de duración en el relajado (`_relaxedMaxDurationDiffSec = 30`): si ambas duraciones se
    conocen y difieren más de 30s, se descarta. Si la del candidato se desconoce (caso habitual en
    resultados de búsqueda), no aplica — si aplicara, volveríamos al problema de C12.
  - El log del match relajado ahora incluye título, canal y ambas duraciones, para poder juzgar de
    un vistazo si el candidato elegido tiene sentido.
      Tests: 3 casos más (rechaza homónimo con duración muy distinta / sigue aceptando cuando la
      duración se desconoce / acepta desfase moderado ≤30s). 37 tests en ese archivo, 152 en la
      suite completa.
      **Nota honesta tras verificar en vivo:** esta guarda de duración **no** fue lo que arregló el
      caso. El homónimo de Nacha Pop dura 220s y el tema correcto 213s — 7s de diferencia, muy por
      debajo del tope de 30s. La guarda sigue siendo correcta y útil como red de seguridad, pero
      atribuirle el arreglo habría sido una conclusión falsa: lo que resolvió el caso fue C14.

- [x] **C14. La causa de fondo: la canción solo existía en YouTube Music, y no la buscábamos ahí.**
      Tras C12 y C13 el síntoma seguía. El dato decisivo llegó de una captura del usuario: el tema
      aparece en **YT Music** con 756 reproducciones — es decir, existe casi con seguridad solo como
      pista auto-generada de YouTube Music (canal `"<Artista> - Topic"`), no como vídeo subido.
      Tres defectos, uno de ellos la razón por la que costó tanto diagnosticar todo lo anterior:
  - **Los logs del isolate nunca llegaron a la terminal.** `sendLog` usaba `dev.log` desde un
    isolate secundario, que solo llega a DevTools, no a la terminal de `flutter run` donde se estaba
    depurando. Las líneas `[JS] ...` sí se veían porque las imprime QuickJS directo a stdout. Es
    decir: **tres rondas de diagnóstico se hicieron a ciegas**, con mensajes que el usuario nunca
    pudo ver. Corregido con `debugPrint` (además del `dev.log`). Lección para el futuro: antes de
    depurar por logs, verificar que los logs efectivamente se ven.
  - **YouTube Music solo se consultaba si la búsqueda de vídeos devolvía CERO resultados**
    (`js_bundle_loader.dart`, `searchVideos`, intento 3). Para un tema de nicho con título genérico,
    la búsqueda normal devuelve 20 homónimos de otros artistas, así que la condición nunca se
    cumplía y jamás se llegaba a mirar donde sí estaba la canción. Ahora se consulta también cuando
    hay **pocos** resultados (<8) y los **añade** a los existentes (dedup por `videoId`) en vez de
    reemplazarlos. En el caso real: 7 candidatos normales + **19 desde YouTube Music** = 26, y el
    correcto pasó el umbral estricto de una, con score 200, sin necesitar el pase relajado.
  - **Regresión de C5 en el orden de clientes:** la query `artista título` —exactamente la que
    funcionaba antes de Fase C— había quedado asignada al cliente ANDROID, cuyo parser falla
    (`Cannot cast SearchMobileHeader to one of SearchHeader`, visible en los logs) y cae a un parseo
    crudo que pierde la duración. Ahora la escalera es: `artista título` en WEB (la más fiable, no
    la más adornada) → `artista título official audio` en WEB → `artista título` en ANDROID como
    cliente alterno → `título` pelado en WEB como último recurso.
      También se añadió un volcado de los candidatos considerados (título, canal, duración, id)
      cuando el pase estricto falla — sin eso no hay forma de distinguir "el vídeo correcto está
      pero el umbral lo rechaza" de "el vídeo correcto no está entre los candidatos", que es
      justamente la diferencia entre ajustar el scoring y buscar en otra fuente.
      Verificado en vivo por el usuario: la pista de nicho reproduce correctamente.

- [x] **C15. Salvedad para pistas sin artista conocido.** El filtro de C13 (el pase relajado solo
      usa lotes de queries que llevaban el artista) dejaba fuera a las pistas cuya metadata no trae
      artista: `bearsArtist` era siempre `false`, `artistBatches` quedaba vacío y el pase relajado
      no corría nunca, con lo que esas pistas volvían a ser irreproducibles. Ahora, si no hay
      artista conocido, ninguna query es "más específica" que otra y todos los lotes son elegibles.

### Resumen de la depuración de Fase C (para no repetir el camino)

El bug reportado ("le doy play a un tema de nicho, carga y salta a la siguiente") tuvo **una sola
causa real** (C14), pero por el camino se encontraron y arreglaron cuatro problemas independientes y
genuinos (C10 carrera en `playCurrent`, C11 `completed` de libmpv sin distinguir fallo de carga, C12
umbral sin degradación, C13 pase relajado mal acotado). Ninguno de los cuatro era *el* bug. Lo que
alargó el diagnóstico fue no verificar primero que los logs de depuración fueran visibles: se
dedujo por eliminación durante tres rondas lo que una sola línea de log habría dicho de inmediato.

---

### Fase D — Búsqueda profunda (plan acordado)

**Problema que resuelve, en concreto.** El buscador normal (Fase A) re-rankea lo que Deezer devuelve
en su pool de 100 resultados por relevancia difusa. Eso deja dos huecos reales, ya medidos:

| Hueco | Caso confirmado | Lo resuelve |
|---|---|---|
| El tema existe y la sintaxis avanzada lo encuentra, pero el texto plano **no lo devuelve en 100** | "Someone Like You" de Adele (posición 1 con `artist:"Adele" track:"Someone Like You"`, ausente del pool con texto plano); "Conqueror" de AURORA | **D3** |
| La colaboración existe pero ninguno de los dos artistas por separado la posiciona bien | "Guess" de Charli xcx con Billie Eilish | **D1** |
| El tema **no está en el índice de búsqueda de Deezer bajo ninguna query**, ni avanzada | La versión solista de "Guess" (solo alcanzable vía `/album/{id}/tracks`) | **D2** |

**Decisión de arquitectura acordada:** un solo punto de entrada en la UI (el botón "Búsqueda
Profunda", hoy deshabilitado en `search_screen.dart:100` con `onPressed: null`) que abre un modal con
dos pestañas, **Exacta** (D3) y **Colaboración** (D1). D2 no es una pestaña: es una acción manual
disparable desde dos sitios distintos (ver abajo). Nada de esto se ejecuta automáticamente — todo
cuesta peticiones y siempre lo decide el usuario.

- [ ] **D3. Búsqueda exacta por artista + título** (pestaña "Exacta").
      Dos campos: Artista y Título. Usa la **misma cascada ya implementada y probada en Fase B**
      (`artist:"X" track:"Y"` → texto plano `"X Y"` → solo título).
  - **Refactor previo, no duplicar lógica:** extraer `PlaylistImportExportService._resolveTrack` /
    `_bestByDuration` / `_queryTitle` / `_primaryArtist` a un módulo compartido nuevo
    (`lib/features/search/exact_track_search.dart`). Hoy esa cascada vive dentro del importador CSV;
    si D3 la reescribe, las dos copias divergen con el tiempo. El importador pasa a consumir el
    módulo compartido, sin cambiar su comportamiento (sigue auto-eligiendo por duración, porque ahí
    no hay humano mirando).
  - **Diferencia clave con el importador:** D3 **no auto-elige**. Devuelve la lista de resultados de
    la cascada, rankeada con `SearchRanking` igual que el buscador normal, y el usuario elige. En
    importación se adivina por duración porque es masivo y desatendido; aquí el usuario está viendo
    la pantalla y sabe cuál quiere.
  - Costo: **1-3 peticiones** (se corta en el primer tier que devuelva algo).
  - Tests: fixtures de la cascada con `artist:"Adele" track:"Someone Like You"` (el caso que el
    buscador normal no puede resolver, ya documentado como test de límite conocido en Fase A).

- [ ] **D1. Colaboraciones de 2 artistas** (pestaña "Colaboración").
      Campos: Artista 1 / Artista 2. **5 peticiones en 2 tandas paralelas (~1s)** en vez de las ~10
      secuenciales del diseño viejo:
  1. Resolver ambos artistas en paralelo (2 req)
  2. En paralelo: texto plano `"Artista1 Artista2"` + `/artist/{A}/top?limit=100` +
     `/artist/{B}/top?limit=100` (3 req)
  3. Filtrar los tops por `contributors` cruzando ambos nombres, sin duplicados
  - Aprovecha que `contributorsJson` ya se persiste (Fase 0) y que `DeezerTrack.contributorsList` ya
    viene deduplicado por id (A13).
  - Sin crawl de discografía por defecto.

- [ ] **D2. "Buscar otras versiones"** — el crawl acotado, como **escape manual**, nunca automático.
      Una sola función compartida con **dos puntos de entrada**, porque son dos momentos distintos:
  - **Entrada 1 — acción en el menú de una canción** (`track_tile.dart`). Aquí no hay ningún fallo
    del que caer: el usuario ya tiene una canción válida y quiere otras versiones de ella (caso
    "Guess": tiene la colaboración, quiere la solista). Usa artista/título/fecha de esa canción, sin
    formularios.
  - **Entrada 2 — botón "buscar más a fondo"** que aparece dentro del modal cuando D1 o D3 devuelven
    vacío o muy pocos resultados. Aquí sí es un fallback.
  - **Implementación compartida:** `getArtistAlbums` (1 req) → ordenar por cercanía de fecha de
    lanzamiento a la de la canción → tomar solo los **10-15 más cercanos** → `/album/{id}/tracks` de
    cada uno → filtrar por `SearchRanking.baseTitle` coincidente. Acotar por fecha es lo que hace
    esto viable: Charli xcx tiene ~50 álbumes y crawlearlos todos sería absurdo.
  - Costo: **11-16 peticiones**. El `RateLimiter` encola (no falla), así que el efecto es lentitud,
    no error — de ahí que deba ser explícito y mostrar progreso en la UI.
  - Prioridad la más baja de las tres: el patrón "Guess" no se repitió en 10 pares probados, así que
    es una rareza de catálogo, no algo sistemático.

**Orden sugerido de implementación:** D3 primero (resuelve los casos ya confirmados en pruebas
reales — Conqueror, Someone Like You — y el refactor compartido con Fase B es barato), luego D1
(más UI pero lógica acotada), y D2 al final, solo si sigue haciendo falta.

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
