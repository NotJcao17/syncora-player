# Plan de implementación — Fase 7: Experiencia Premium e IA

> Documento de planificación redactado tras una sesión de diseño y discusión de alcance.
> Las decisiones aquí registradas están **cerradas** salvo que se indique lo contrario.
> Los límites de la API de Gemini y los endpoints de Deezer fueron verificados durante la sesión.

## Alcance de la fase (según Documento Maestro, sección 5)

1. Cola reordenable drag & drop → **ampliado**: sistema de cola dual (automática + manual)
2. Auto-Skip inteligente completo (UI + cola dinámica)
3. Crossfade en ambas plataformas
4. Integración Gemini con flujo BYOK unificado (Edge Function)
5. Estadísticas Wrapped

Añadido durante la sesión de diseño (no estaba explícito en el Documento Maestro):
- Radio / cola infinita (sin IA, sobre endpoints de Deezer)
- Smart Shuffle **absorbido** dentro de "Crear cola con IA" (ver decisión D-9)
- **Límite de cuentas (250)** y **modo local / sin cuenta** — surgieron del análisis de
  escalabilidad (Documento Maestro §4.5 y §4.6). Van en esta fase porque el modo local **cambia
  cómo funcionan las Estadísticas** (7.G) y conviene decidirlo antes de construirlas.

---

## Hallazgos del código actual (verificados, leer antes de implementar)

Estos hallazgos salieron de inspeccionar el código durante la redacción del plan y **cambian el orden
de trabajo**. No son suposiciones.

### H-1. El historial de escucha NUNCA se registra (bloqueante para Estadísticas)

`ListeningHistoryDao.recordEntry()` (`lib/data/local_db/daos/listening_history_dao.dart:10`)
**no tiene ni un solo llamador en toda la app**. Toda la infraestructura existe:

- Tabla Drift `ListeningHistory` (`lib/data/local_db/syncora_database.dart:61`)
- Tabla Supabase `listening_history` + RLS + índice (migraciones `...000000`, `...000002`, `...000004`)
- DAO con `recordEntry`, `getRecentHistory`, `getTopArtistIds`
- Sincronización a la nube (`sync_service.dart:314`)
- Consumidor en Inicio (`home_providers.dart:36`, secciones personalizadas)

...pero nadie escribe. Consecuencias:

- **Estadísticas no tiene ninguna fuente de datos hoy.** Cero filas históricas.
- Las "secciones personalizadas" de Inicio **siempre** caen al fallback hardcodeado
  (Coldplay / Bad Bunny / Dua Lipa — `home_providers.dart:42`). La personalización de Inicio
  está muerta desde que se escribió.

→ **Por eso el registro de historial es lo primero de la fase (7.0):** los datos necesitan tiempo
para acumularse mientras se construye el resto. Si se deja para el final, se llega al Wrapped con
la base vacía y sin nada que mostrar ni con qué probar.

### H-2. La sincronización de historial duplica filas en cada sync (bug latente)

`SyncService._syncListeningHistoryInternal()` (`sync_service.dart:314`) lee las **últimas 100**
entradas locales y las inserta en Supabase con un `.insert()` plano
(`supabase_history_repository.dart:28`), sin clave de deduplicación, sin marca de "ya sincronizado"
y sin `upsert`.

Hoy es inofensivo **solo porque la tabla local siempre está vacía** (H-1). En cuanto se active el
registro, cada sincronización re-insertará las mismas 100 filas: las estadísticas quedarían
infladas de forma arbitraria y el presupuesto de 500 MB de Supabase se quemaría rápido.

→ **Debe arreglarse en el mismo paso 7.0, antes de activar el registro.**

### H-3. La cola es una lista plana — el modelo dual es un refactor real, no un añadido

`SyncoraPlayerState` (`syncora_player_controller.dart:22`) tiene:

```dart
final List<SyncoraTrack> queue;   // una sola lista
final int currentIndex;           // puntero, las pistas ya sonadas se quedan en la lista
final bool shuffle;                // flag; el shuffle se resuelve en _nextIndex()
```

No hay separación auto/manual, las pistas reproducidas **no se eliminan** (solo avanza
`currentIndex`), y `addToQueue()` (`:369`) hace `queue.add(track)` al final — no inserta al frente
del bloque manual. El shuffle se calcula al vuelo en `_nextIndex()` (`:807`) en vez de reordenar
una cola automática materializada.

Además hay estado dependiente que debe migrar con el modelo:
- `PlayerSessionStorage` (persistencia de sesión — la cola se guarda y restaura entre arranques)
- `_skipSilently()` (`:579`, bucle iterativo offline de Fase 6)
- `_nextIndex()` (`:807`, shuffle/repeat)
- Los controles del SO (`os_controls/`), que exponen la cola al sistema

→ 7.A es la pieza de mayor riesgo de regresión de toda la fase. Todo lo demás (radio, auto-skip,
cola con IA) se apoya en ella, así que va primero después del prerequisito de datos.

### H-4. No existe infraestructura de Edge Functions todavía

No hay carpeta `supabase/functions/`. Las 7 migraciones existentes son solo SQL. La Edge Function
de IA es infraestructura **nueva** desde cero: setup, deploy, secreto `GEMINI_API_KEY`, y el
primer flujo de despliegue del proyecto que no es `supabase db push`.

### H-5. El "modo local" está más cerca de lo esperado, pero el gating de edición está mal atado

Inspeccionando el código para planear el modo sin cuenta (7.I), tres hallazgos:

- **La superficie de Supabase es pequeña y ya está semi-aislada.** Solo 13 archivos tocan
  `Supabase.instance`, casi todos con 1-2 usos. Los repositorios **ya tienen guardas de nulo**
  (`final client = _client; if (client == null) return;` —
  `supabase_history_repository.dart:23-26`), así que buena parte del camino "sin nube" ya existe.
- **Las playlists locales ya son un concepto soportado:** `Playlists.remoteId` es *nullable*
  (`syncora_database.dart:18`) y solo se marca tras respaldar en la nube. Una playlist sin
  `remoteId` ya funciona hoy — el modo local no inventa un estado nuevo, generaliza uno existente.
- ⚠️ **El problema real:** el gating de "no puedes editar" está atado a **`isConnectedProvider`
  (estado de red)**, no a "tienes cuenta". Se ve en `library_screen.dart:47, 125, 147-210, 603`
  (crear playlist, editar nombre, eliminar, etc.). En modo local **la edición debe funcionar sin
  internet**, porque no hay nada en la nube que mantener consistente. La condición tiene que pasar
  de `isConnected` a algo como `canEdit = isLocalMode || isConnected`. Es el refactor central de
  7.I y toca ~10 puntos de UI.
- **La sincronización se dispara explícitamente desde la UI** (~10 llamadas a `syncServiceProvider`
  en `library_screen.dart`, `album_detail_screen.dart`, `playlist_detail_screen.dart`), no
  automáticamente en background. Eso facilita neutralizarla en modo local, pero hay que cubrir
  todos los puntos.
- **El router ya tiene el gate en un solo lugar:** `app_router.dart:59` redirige a `/auth` si
  `currentUser == null`. Es exactamente el punto donde entra el modo local.

### H-6. `lastError`/`lastErrorMessage` del controlador nunca llegan a la UI (descubierto al planear 7.C)

Al implementar la Fase 7.C (toast de auto-skip lógico) se verificó que `SyncoraPlayerState.lastError`/
`lastErrorMessage` — el campo que la Fase 1 diseñó para el "aviso visual" de la pausa por 403
persistente (Documento Maestro §2.3, guard anti-bucle) — **no tiene ningún consumidor en la UI**:
`grep` de `lastError`/`lastErrorMessage` en `lib/` solo encuentra el propio
`syncora_player_controller.dart` donde se escribe, y no existe ningún `ref.listen` sobre el estado
del reproductor en toda la app. La "pausa inmediata" del guard 403 sí funciona (el motor se detiene
de verdad), pero el "aviso visual" que la acompaña, pese a estar en el diseño desde la Fase 1, nunca
se conectó a ningún widget — el usuario ve la música detenerse sin explicación.

→ Como 7.C necesita exactamente el mismo mecanismo (escuchar cambios de `lastError`/
`lastErrorMessage` y mostrar feedback al usuario) para el toast nuevo de auto-skip lógico, se
aprovecha la misma fase para cablear también el aviso del guard 403/red que quedó pendiente desde
Fase 1 — no es una decisión nueva, es completar una que ya estaba cerrada y que resultó estar a
medio implementar.

### H-7. El modelo Gemini y la forma de llamar a la API cambiaron desde que se escribió el plan (verificado al planear 7.E)

Antes de implementar 7.E se verificó contra `ai.google.dev` (navegador, agosto 2026) lo que el plan
ya advertía que había que revisar ("no hardcodear sin verificar"). Dos cambios reales:

1. **`gemini-3.1-flash-lite` ya tiene fecha de baja anunciada: 7 de mayo de 2027**, con
   `gemini-3.5-flash-lite` como reemplazo recomendado explícito (lanzado 21 de julio de 2026, sin
   fecha de baja anunciada). La decisión D-13 elige el **nivel** "Flash-Lite" (costo/velocidad para
   generación estructurada, no razonamiento complejo), no la versión exacta — así que el modelo a
   usar es **`gemini-3.5-flash-lite`**, no `gemini-3.1-flash-lite` (que ya es la versión saliente
   de ese mismo nivel).
2. **La API de Gemini migró a la "API de Interactions"** (`v1beta/interactions`), presentada como
   GA y recomendada para "todos los modelos y funciones más recientes" — reemplaza al endpoint
   clásico `generateContent`/`contents`/`candidates[0].content.parts[0].text`. Forma confirmada
   (capturada de un ejemplo real de la documentación):
   ```
   POST https://generativelanguage.googleapis.com/v1beta/interactions
   Header: x-goog-api-key: <API_KEY>
   Body: {
     "model": "gemini-3.5-flash-lite",
     "input": "<prompt>",
     "response_format": {
       "type": "text",
       "mime_type": "application/json",
       "schema": { ...JSON Schema... }
     }
   }
   ```
   La respuesta expone el texto estructurado vía `output_text` (equivalente al viejo
   `candidates[0].content.parts[0].text`). El BYOK (header `x-goog-api-key` con la key del
   usuario) mapea igual de bien a este endpoint que al viejo.

→ La Edge Function de 7.E debe implementarse contra la API de Interactions con
`gemini-3.5-flash-lite`, no contra `generateContent` con `gemini-3.1-flash-lite` como el plan
originalmente esbozaba. No se verificaron en esta sesión los límites RPM/RPD/TPM exactos del free
tier para `gemini-3.5-flash-lite` (la tabla de límites de la documentación no cargó los valores por
nivel al navegarla) — la fila de la tabla de abajo con los valores de `gemini-3.1-flash-lite` queda
como referencia de orden de magnitud, no como cifra exacta vigente; vale la pena que quien
implemente 7.E la revise una vez más contra AI Studio/la cuenta real antes de fijar los umbrales de
rate-limit de 7.E.3.

> ⚠️ **CORRECCIÓN (pruebas manuales post-Fase 7, 2026-08-23): el punto 2 de arriba era falso.**
> No existe ninguna "API de Interactions" pública de Gemini en `v1beta/interactions` — nunca se
> verificó realmente contra la documentación real, pese a lo que este hallazgo afirmaba. Desplegada
> contra el proyecto real, **cada** llamada a Gemini fallaba con un error HTTP, tanto con la llave
> compartida como con BYOK (el usuario reportó "la IA no está disponible" para las 4 funciones, sin
> excepción). `gemini.ts` se corrigió para usar el endpoint real y estable de Gemini,
> `v1beta/models/{model}:generateContent`, con salida estructurada vía
> `generationConfig.responseMimeType: "application/json"` + `responseSchema` (equivalente moderno
> del viejo `response_schema` suelto), leyendo el resultado de
> `candidates[0].content.parts[0].text` en vez de un inexistente `output_text`. El punto 1 (versión
> del modelo, `gemini-3.5-flash-lite`) no tiene evidencia en contra y se dejó igual. Ningún test de
> `deno test` había ejercitado la llamada HTTP real contra Gemini (todos mockean `fetch`), así que
> esto nunca se detectó hasta la primera prueba manual real con una cuenta y una API key reales.
> Corregido en `supabase/functions/ai-assistant/gemini.ts`, redesplegado contra el proyecto real.

### H-8. "Intercalar 1 cada 3" (D-9) con paso fijo deja las sugerencias sobrantes en un solo bloque al final (verificado en la revisión independiente de 7.F.2)

El plan (7.F.2) especifica el intercalado como "1 sugerida cada ~3" sin definir qué pasa cuando hay
más sugerencias que huecos disponibles a ese paso fijo. La implementación inicial usaba
literalmente ese paso fijo (`_aiInterleaveEvery = 3`), y con los defaults del propio atajo "✨
Mejorar esta cola" (D-9: 25 sugerencias) contra una `autoQueue` típica bastante más corta, el
resultado no se parecía a un intercalado real: con una `autoQueue` de 20 pistas se intercalaban 6 y
las otras 19 quedaban pegadas en un solo bloque al final — justo el caso de uso principal de la
función, no un borde raro.

→ `interleaveIntoAutoQueue` (`syncora_player_controller.dart`) se corrigió a un **paso adaptativo**
(`autoQueue.length ~/ tracks.length`, mínimo 1) que reparte las sugerencias a lo largo de toda la
cola automática existente en vez de un paso fijo — solo queda un bloque residual al final cuando
hay estructuralmente más sugerencias que huecos posibles (`autoQueue` muy corta). Detalle completo
y ejemplo numérico en `docs/fases/fase_7_f.md`, sección 7.F.2.

---

## Datos verificados en la sesión (Gemini y Deezer)

### Límites de Gemini API — free tier (agosto 2026)

| Modelo | RPM | RPD | TPM | Contexto | Salida máx. |
|---|---|---|---|---|---|
| **Gemini 3.1 Flash-Lite** (elegido) | 15 | 1.000 | 250.000 | 1.048.576 | 65.536 |
| Gemini Flash | 10 | 250 | 250.000 | 1.048.576 | 65.536 |
| Gemini Pro | — | — | — | — | **fuera del free tier desde abril 2026** |

**No existe límite de "tokens por día" (TPD) publicado.** Google limita por RPM / TPM / RPD.
El recurso escaso es **RPD (peticiones por día)**, no los tokens.

Implicación de diseño confirmada: **mandar una playlist completa como contexto no es problema.**
Una playlist de 1.000 canciones en JSON compacto (`{id, title, artist}`) ≈ 15-20k tokens — muy
por debajo del TPM de 250k/min y ridículamente lejos de la ventana de 1M. Lo que hay que cuidar
es *cuántas veces* se llama al día, no cuánto pesa cada llamada.

⚠️ El identificador exacto del modelo (`gemini-3.1-flash-lite` vs. el que esté vigente) **debe
confirmarse contra AI Studio al momento de implementar** — Google rota estos nombres con
frecuencia (en 2026 ya hubo 2.5 → 3.1 → 3.5). No hardcodear sin verificar.

### API de Gemini: es *stateless*, el contexto lo mantenemos nosotros

No existe una "sesión de chat" persistente del lado del servidor. Lo que el SDK llama `ChatSession`
es azúcar del cliente: **reenvía todo el historial de turnos en el array `contents` de cada
llamada**. Para el flujo de "afinar esta playlist" (D-4), la Edge Function / el cliente debe
guardar y reenviar los turnos previos explícitamente.

Nota para prototipar prompts: AI Studio inyecta su propio `system_instruction` y configuración de
generación que **no** están presentes al llamar la API en crudo. Los prompts de prueba deben
validarse con la configuración real que usará la Edge Function (system prompt propio +
`response_schema` + temperatura), no en la interfaz de chat. El botón "Get code" de AI Studio
exporta exactamente esa llamada.

### Endpoints de Deezer para radio (verificados)

| Endpoint | Devuelve |
|---|---|
| `/artist/{id}/radio` | "Smart radio" curada por Deezer, sembrada en ese artista |
| `/artist/{id}/related` | Artistas relacionados/similares |
| `/radio`, `/radio/genres`, `/radio/top`, `/radio/{id}/tracks` | Radios genéricas por género (sin semilla de artista) |

**No existe** radio por track individual ni por playlist. La semilla siempre es artista o género.

---

## Decisiones de diseño cerradas

| # | Decisión |
|---|---|
| **D-1** | Cola dual: automática (regenerable) + manual (persistente). Cambiar shuffle/normal o de playlist **solo** regenera la automática. Las funciones de IA **nunca** borran la cola manual. |
| **D-2** | La cola manual es **FIFO** dentro de su bloque (como Spotify): agregar A y luego B reproduce A, luego B. |
| **D-3** | Las pistas ya reproducidas **se eliminan** de la cola. "Anterior" usa una **pila de historial de reproducción única** (sin importar de qué cola vino la pista) — al volver desde una pista manual, regresa a esa pista manual, no a la automática (difiere de Spotify a propósito). |
| **D-4** | Crear playlist con IA: entrada de texto libre (primaria) + panel de parámetros opcional colapsado + iteración post-generación. La edición manual de la lista previa (+/-) es **local y gratuita**; solo "afinar con IA" gasta una petición. |
| **D-5** | Los límites numéricos (cantidad, máx. por artista) se aplican **programáticamente tras recibir la respuesta**, nunca confiando solo en la instrucción del prompt. Se pide ~30% de más y se recorta (verificado empíricamente: pidiendo 1.000 devuelve entre 800 y 1.200). |
| **D-6** | Toda salida de IA usa **`response_schema` (salida estructurada)**, nunca texto libre parseado a mano. |
| **D-7** | Para "quitar canciones", el schema restringe la salida a **IDs que ya existen** en la playlist enviada. Es estructuralmente imposible que invente una canción a borrar. |
| **D-8** | Para "agregar canciones", lo que sugiere la IA (`{title, artist}`) **nunca se guarda tal cual**: se busca en Deezer y solo se inserta el registro con los datos canónicos de Deezer. Si no hay match, se descarta. Imposible ensuciar la BD con un título inventado. |
| **D-9** | Smart Shuffle **no es una función separada**: es el toggle "intercalar con la cola automática" dentro de "Crear cola con IA", más un atajo que prellena el formulario (25 canciones, basada en la cola actual, intercalar) y dispara directo. |
| **D-10** | Radio / cola infinita: **sin IA**, solo Deezer. Activada por defecto. |
| **D-11** | El selector "basado en esta playlist" solo lista **playlists propias** (`user_id` = usuario actual), nunca públicas/compartidas de terceros — cierra el vector de inyección vía contenido ajeno. |
| **D-12** | Las Edge Functions de IA **nunca escriben en la base de datos**. Solo llaman a Gemini y devuelven una sugerencia estructurada; el `INSERT`/`DELETE` real lo ejecuta el cliente con el JWT del usuario, después de una vista previa confirmada. |
| **D-13** | Modelo por defecto: **Flash-Lite** para todas las funciones (tareas de generación estructurada, no razonamiento complejo). Modelos superiores quedan como opción solo para usuarios BYOK. |
| **D-14** | Ícono de IA: `stars-broken` (variante *bold* mientras una generación está en curso), consistente en los 4 puntos de entrada. |
| **D-15** | Las funciones de IA viven **integradas en su sección** (biblioteca, cola, playlist, buscador), no en una pantalla dedicada. |
| **D-16** | Estadísticas: se registra una escucha si supera **50% de la duración o 30 segundos** (lo que sea menor). |
| **D-17** | Vistas de estadísticas: Semanal y Mensual salen de **datos crudos** (`listening_history`, ventana móvil de 7/30 días); Anual y "Desde el inicio" salen de **`user_stats_monthly`** (agregado). |
| **D-18** | El Anual es una **ventana móvil de los últimos 12 meses**, no un corte de calendario. Siempre disponible, aunque el usuario lleve 3 meses. |
| **D-19** | **No se podan** los registros mensuales agregados (ver estimación de escalabilidad más abajo). No se crea tabla `user_stats_yearly`. |
| **D-20** | Compartir Wrapped: **solo exportar imagen**, no URL pública. |
| **D-21** | El estado "canción no disponible" (gris) es **solo de sesión, no persistido** — se resetea al abrir la app. Evita que un falso positivo deje una canción marcada como rota para siempre. |
| **D-22** | **Límite de 250 cuentas** en la nube, aplicado con un Auth Hook "Before User Created". El tope vive en una tabla de configuración (no hardcodeado) para poder subirlo con un `UPDATE`, sin redeploy. |
| **D-23** | **Modo local / sin cuenta** disponible **desde el lanzamiento**, no solo como salvavidas al llenarse el cupo. Coherente con el objetivo del proyecto ("100% gratuito, privado") y hace que el límite de cuentas nunca bloquee del todo a nadie. |
| **D-24** | El modo local **no es un estado de red, es un estado de sesión**: `canEdit = isLocalMode \|\| isConnected`. Sin nube que sincronizar, la restricción Online-First no aplica (ver H-5). |
| **D-25** | Un usuario local puede **migrar a cuenta** (subir su biblioteca local a la nube) si hay cupo. La migración es **one-way**: no se implementa "bajar de cuenta a local". |

---

# Fases de implementación

Orden: **7.0 → 7.A → 7.B → 7.C → 7.D → 7.E → 7.F → 7.H → 7.I → 7.G**

El orden no es negociable en tres puntos:
- **7.0 va primero** (los datos de historial necesitan acumularse desde ya).
- **7.A antes que 7.B / 7.C / 7.F** (todo se apoya en el modelo de cola).
- **7.I (modo local) antes que 7.G (estadísticas)** — el modo local **cambia de dónde salen las
  estadísticas** (sin `pg_cron` ni Supabase no hay rollup mensual en la nube; ver 7.I.6).
  Construir 7.G primero significaría rehacerlo. 7.H va justo antes de 7.I por afinidad temática
  (ambas tocan auth), aunque técnicamente son independientes entre sí.

---

## Fase 7.0 — Prerequisito: registro de historial de escucha

> Sin esto, Estadísticas no tiene datos y la personalización de Inicio sigue muerta (H-1).
> Va primero para que el historial se acumule durante el resto de la fase.

- [x] **7.0.1** Arreglar la duplicación de sincronización (H-2) **antes** de activar el registro:
      añadir columna `syncedAt` (o `isSynced`) a la tabla Drift `ListeningHistory`; que
      `_syncListeningHistoryInternal()` seleccione solo las no sincronizadas y las marque tras
      insertar. Alternativa complementaria: clave natural única en Supabase
      (`user_id, track_id, listened_at`) + `upsert` con `onConflict`, como red de seguridad ante
      reinstalaciones.
- [x] **7.0.2** Registrar la escucha desde `SyncoraPlayerController`: acumular tiempo realmente
      reproducido de la pista actual y llamar a `recordEntry()` cuando se cumpla el umbral D-16
      (≥50% de la duración **o** ≥30s, lo que sea menor). Cuidar de **no** contabilizar dos veces
      la misma pista si el usuario retrocede y la vuelve a escuchar dentro de la misma sesión
      continua, y de que un `seek` manual no infle el tiempo acumulado.
- [x] **7.0.3** Rellenar `genre` en el registro. La tabla lo tiene (`ListeningHistory.genre`) pero
      `DeezerTrack` no siempre lo trae en los resultados de búsqueda — verificar de dónde sale hoy
      (probablemente requiere `/album/{id}` o el track enriquecido) y decidir: rellenar cuando esté
      disponible y dejar `NULL` si no, o resolverlo diferido. **Sin género no hay "top géneros"
      en Estadísticas**, así que esta decisión afecta directamente a 7.G.
- [x] **7.0.4** Verificar que las secciones personalizadas de Inicio (`home_providers.dart:36`)
      empiezan a usar historial real en vez del fallback hardcodeado, una vez haya datos.
- [x] **7.0.5** Tests: umbral de registro (justo por debajo / justo por encima, pista corta <60s
      donde manda la regla de 30s), no-duplicación en sincronización, marca de sincronizado.

---

## Fase 7.A — Cola dual (automática + manual)

> Refactor de mayor riesgo de la fase (H-3). Todo lo demás depende de esto.

### Modelo de datos

- [x] **7.A.1** Rediseñar `SyncoraPlayerState`: separar `autoQueue` y `manualQueue` (o una lista
      única con un flag `isManual` por entrada — evaluar cuál rompe menos el código existente).
      La pista actual sale de la manual si hay algo ahí, si no, de la automática.
- [x] **7.A.2** Pila de historial de reproducción (D-3) para "anterior": las pistas consumidas
      salen de su cola y entran a la pila, sin importar su origen.
- [x] **7.A.3** Materializar la cola automática: hoy el shuffle se resuelve al vuelo en
      `_nextIndex()` (`:807`). Con el modelo nuevo, cambiar shuffle↔normal **regenera la cola
      automática** a partir del contexto activo (`activeContextId`), sin tocar la manual.
- [x] **7.A.4** Cambiar de playlist regenera la automática, conserva la manual.
- [x] **7.A.5** `addToQueue()` (`:369`) pasa a insertar en la cola manual respetando FIFO (D-2),
      no `add()` al final de la lista global.
- [x] **7.A.6** Migrar `PlayerSessionStorage` al nuevo modelo (persiste y restaura ambas colas +
      la pila de historial). Cuidar la compatibilidad con sesiones guardadas del formato viejo:
      lo más simple y seguro es **descartar la sesión antigua** si no matchea el formato nuevo,
      en vez de intentar migrarla.
- [x] **7.A.7** Adaptar `_skipSilently()` (`:579`, Fase 6): el bucle iterativo debe recorrer ambas
      colas en el orden correcto de reproducción.
- [x] **7.A.8** Adaptar los controles del SO (`os_controls/`) que exponen la cola al sistema.

### UI de cola

- [x] **7.A.9** Pantalla/hoja de cola con las dos secciones visualmente diferenciadas
      ("A continuación" manual / "Siguiente de {playlist}" automática), según el Documento Maestro
      §2.1.5 (vista superpuesta en móvil, sidebar derecho colapsable en PC).
- [x] **7.A.10** Drag & drop para reordenar (el ítem del alcance oficial). Definir si se permite
      arrastrar entre secciones o solo dentro de cada una — **recomendación: solo dentro de cada
      sección**, mover una pista automática al bloque manual es semánticamente confuso.
- [x] **7.A.11** Deslizar a la izquierda para eliminar; deslizar a la derecha (en listas) para
      agregar a la cola; botón "Editar" con selección múltiple (eliminar / mover arriba) — todo
      del Documento Maestro §2.1.5.
- [x] **7.A.12** Empty states, tanto de la manual vacía como de la cola completa vacía.

### Tests

- [x] **7.A.13** El algoritmo de reordenamiento (índices se actualizan correctamente) — está
      explícitamente pedido en `matriz_de_pruebas.md` como test automatizado de Fase 7.
- [x] **7.A.14** Casos: agregar 2 manuales seguidas → orden FIFO; cambiar shuffle no toca la
      manual; cambiar de playlist no toca la manual; "anterior" tras consumir una manual vuelve a
      esa manual; consumir pistas las elimina de la cola; restaurar sesión reconstruye ambas colas.

---

## Fase 7.B — Radio / cola infinita (sin IA)

> Solo Deezer. No consume presupuesto de Gemini. Activada por defecto (D-10).

### Parámetros acordados

| Parámetro | Valor |
|---|---|
| Disparo | Cuando quedan **≤5** pistas en la cola automática |
| Artistas semilla | **5** por disparo |
| Si hay menos de 5 artistas distintos | Completar con `/artist/{id}/related` |
| Canciones por artista | **~5** (no toda la lista que devuelva el endpoint) |
| Lote objetivo | **25** canciones válidas |
| Filtro de calidad | `rank` ≥ el mismo umbral de "búsqueda popular" (`SearchRanking.popularTrackMinScore`, rank ~300k) |
| Selección de semillas | **Muestreo aleatorio ponderado por frecuencia** (no top-N fijo) |

- [x] **7.B.1** Añadir a `DeezerApi` (`lib/data/apis/deezer_api.dart`) los endpoints
      `/artist/{id}/radio` y `/artist/{id}/related`, reusando la caché LRU genérica `_LruCache`
      que ya existe ahí.
- [x] **7.B.2** Servicio de radio: cuenta frecuencia de artistas en el contexto actual
      (playlist/cola), muestrea 5 semillas ponderadas por frecuencia, pide sus radios en
      **paralelo** (`Future.wait`, como ya se hizo en A11 del plan del buscador).
- [x] **7.B.3** Pipeline "dirigido por cuota": filtrar por rank → deduplicar contra la cola actual,
      la playlist de origen y las últimas N reproducidas → si no se llega a 25, seguir tirando de
      más artistas (siguientes por frecuencia, o `/related` de los ya elegidos) hasta completar o
      agotar fuentes razonables. Pedir con buffer para no quedarse corto tras filtrar.
- [x] **7.B.4** Cubrir explícitamente los casos límite de variedad de artistas:
  - **1 solo artista** (álbum): radio del artista + `/related` para no repetir siempre lo mismo
  - **2-4 artistas**: usar los que hay + completar con `/related`
  - **Muchos artistas** (playlist variada): el muestreo ponderado ya lo resuelve
  - **Cola vacía / sin contexto**: fallback a `/radio/genres` o charts
- [x] **7.B.5** Anexar el lote **al final de la cola automática**, en segundo plano, sin tocar la
      manual ni interrumpir la reproducción.
- [x] **7.B.6** Toggle en Configuración para desactivarlo (`settings_screen.dart` ya tiene el
      patrón de `SwitchListTile`, es trivial). Por defecto **ON**.
- [x] **7.B.7** Tests con fixtures grabadas de `/artist/{id}/radio` y `/related` (mismo patrón que
      `test/fixtures/deezer_search/`): muestreo ponderado, deduplicación, filtro de rank,
      completado de semillas cuando hay menos de 5 artistas.

---

## Fase 7.C — Auto-Skip inteligente completo

> Solo cubre el **Auto-Skip lógico** (canción no resoluble en catálogo, estando online).
> **No** toca la política de 403/red (máx. 1 reintento → pausa, Fase 1, ya cerrada) ni el
> skip silencioso offline (`_skipSilently`, Fase 6, ya cerrado).

- [x] **7.C.1** Toast al auto-saltar por error lógico: *"{título} no disponible — saltada"*.
      **Solo** en este caso: ni en el skip por red (que ya tiene su flujo de pausa+aviso) ni en el
      skip manual del usuario.
- [x] **7.C.2** Marcar la pista en gris en la cola/lista. Estado **de sesión, no persistido**
      (D-21).
- [x] **7.C.3** Guard de cascada: si fallan **3 pistas seguidas por error lógico**, detener el
      auto-skip y mostrar un aviso resumen con opción de continuar o pausar. Evita vaciar una
      playlist entera en silencio cuando hay muchos matches rotos.
- [x] **7.C.4** Cablear el salto al modelo de cola dual (7.A): saber de qué cola vino la pista
      fallida, eliminarla de la correcta y no romper el FIFO de la manual.
- [x] **7.C.5** Tests: 1 fallo aislado → salta y avisa; 3 seguidos → se detiene; el contador se
      resetea al reproducir algo correctamente; fallo en cola manual no descoloca la automática.

**Descartado a propósito:** acción "Corregir coincidencia de YT" dentro del toast (simplicidad).

---

## Fase 7.D — Crossfade en ambas plataformas

> Restringido a **pistas descargadas/cacheadas** (Pitfall #17). El diseño técnico ya está definido
> en el Documento Maestro §2.4 y no se cambió en esta sesión.

- [x] **7.D.1** **Windows (`media_kit`):** instancias duales con fade-in/fade-out paralelo vía el
      control de volumen de cada instancia. Implementado dentro de `CrossfadeAudioEngine` (ver
      7.D.3) — no hizo falta código específico de plataforma, el wrapper agnóstico cubre Windows
      con dos `MediaKitEngine` igual que cubre Android.
- [x] **7.D.2** **Android (`just_audio`):** dos `AudioPlayer` simultáneos y el fade cruzado. Mismo
      mecanismo que 7.D.1: `CrossfadeAudioEngine` envuelve dos `JustAudioEngine` sin código
      específico de plataforma (se descartó un `CrossfadeAudioHandler` separado por ser
      redundante con el wrapper genérico ya agnóstico).
- [x] **7.D.3** Abstracción común en `AudioEngine` para que el controlador no tenga que saber de
      qué plataforma se trata. `CrossfadeAudioEngine` (`lib/features/player/audio_engine/
      crossfade_audio_engine.dart`) implementa `AudioEngine` envolviendo dos instancias del motor
      real (`createEngine` factory), con `_standby` perezoso. Ver `docs/fases/fase_7_d.md`.
- [x] **7.D.4** Guard explícito: si la siguiente pista **no** está descargada, no intentar
      crossfade (transición normal). Verificado contra `DownloadedTrackDao` en
      `_playCurrentInternal()`, junto con las otras 3 condiciones (setting > 0, pista actual
      también local, motor reproduciendo algo).
- [x] **7.D.5** Ajuste de duración del crossfade en Configuración (off / 2s / 4s / 6s), off por
      defecto. `crossfadeDurationProvider` en `player_providers.dart` + selector de píldoras nuevo
      en `settings_screen.dart`.
- [ ] **7.D.6** Prueba humana obligatoria (`matriz_de_pruebas.md` Fase 7): activar crossfade en una
      pista descargada en Windows y verificar la transición; repetir en Android.

---

## Fase 7.E — Infraestructura de IA (Edge Function + BYOK)

> Infraestructura nueva desde cero (H-4). Es la base de las 4 funciones de 7.F, así que va antes.

### Reglas de seguridad (del Documento Maestro §4 + decisiones de esta sesión)

1. La `GEMINI_API_KEY` vive **solo** como secreto de Supabase Edge Functions, jamás en el cliente
   (Pitfall #15).
2. **BYOK unificado:** si el usuario trae su llave, viaja en el header `X-User-AI-Key` a la
   **misma** Edge Function, que la reenvía a Gemini y la descarta. Nunca se guarda, nunca se
   loguea, nunca bypasea la función (Pitfall #21). En el cliente se guarda con
   `flutter_secure_storage`.
3. El cliente de Supabase dentro de la función se inicializa **siempre con el JWT del usuario**,
   nunca con `SERVICE_ROLE_KEY`.
4. **D-12: la función no escribe en la BD.** Solo devuelve sugerencias.
5. Rate limit interno por usuario para la llave compartida; se omite o eleva en modo BYOK.

### Tareas

- [x] **7.E.1** Crear `supabase/functions/` y la función de IA. Definir si es **una** función con
      un parámetro de "acción" o **una por caso de uso** — recomendación: **una sola función** con
      acción, para no duplicar la lógica de auth, rate limit, BYOK y saneamiento cuatro veces.
- [x] **7.E.2** Migración SQL: tabla de rate limit por usuario (contador + ventana).
- [x] **7.E.3** Implementar el rate limit por usuario (N llamadas/hora), con mensaje de error claro
      y accionable en la UI, no un fallo genérico.
- [x] **7.E.3b** Distinguir en la UI **dos** casos de error distintos, cada uno con su propio
      mensaje (la función debe devolver un código de error diferenciado, no un 500 genérico, para
      que el cliente sepa cuál mostrar) — el contrato (códigos `rate_limited_user`/
      `shared_quota_exhausted` + mensajes) está completo en 7.E; la UI que los muestra en pantalla
      se cablea cuando la Fase 7.F construya las pantallas que invocan la función.
  - **Rate limit personal** (este usuario hizo muchas peticiones seguidas): mensaje de "espera un
    momento", sin mencionar la llave compartida.
  - **Cuota diaria compartida agotada** (RPD de la llave de la plataforma se acabó para todos, ver
    §4.1): *"La IA gratuita de la app se agotó por hoy — ingresa tu propia API key gratuita de
    Gemini para seguir usando esta función"*, con un botón directo al campo de BYOK de 7.E.8. La
    cuota diaria de Gemini se resetea a medianoche hora del Pacífico.
- [x] **7.E.4** Definir los `response_schema` de las 4 funciones (D-6), incluido el schema
      restringido a IDs existentes para "quitar" (D-7).
- [x] **7.E.5** Saneamiento anti-inyección de la entrada del usuario y separación clara entre
      instrucciones del sistema y datos del usuario en el prompt.
- [x] **7.E.6** Confirmar el identificador del modelo vigente contra AI Studio antes de fijarlo.
      Dejarlo en una constante/variable de entorno de la función, **no** disperso por el código.
- [x] **7.E.7** Cliente Dart: servicio que invoca la Edge Function, adjunta el JWT, y adjunta
      `X-User-AI-Key` si el usuario configuró llave propia.
- [x] **7.E.8** UI de BYOK en Configuración: campo para pegar la llave, guardado en
      `flutter_secure_storage`, opción de borrarla, y aviso de qué implica.
- [x] **7.E.9** Tests con mocks (pedidos explícitamente en `matriz_de_pruebas.md` Fase 7):
      **verificar que la Edge Function recibe `X-User-AI-Key`, la usa para llamar a Gemini, y no
      la guarda ni la loguea.** Además: rate limit dispara correctamente, y la función nunca
      ejecuta mutaciones.

---

## Fase 7.F — Funciones de IA

Las 4 funciones, todas sobre la infraestructura de 7.E, todas con vista previa antes de aplicar.

> **Estado:** 7.F.1, 7.F.2, 7.F.3 y 7.F.4 cerradas, commiteadas y pusheadas (ver
> `docs/fases/fase_7_f.md` para el detalle de cada una: arquitectura, bugs encontrados y
> corregidos). 7.F.3/7.F.4 se implementaron juntas en una sola tanda (metodología de eficiencia de
> tokens de `CLAUDE.md`) y revisadas por el propio orquestador leyendo el diff directamente, sin
> subagente separado (ninguna toca invariantes de riesgo real como D-1/cola o auth).

### 7.F.1 — Crear playlist con IA

Entrada: botón con ícono `stars-broken` en **Biblioteca**, junto a "crear playlist".

- [x] Entrada primaria: caja de texto libre.
- [x] Panel de parámetros **opcional y colapsado**: cantidad de canciones (presets 25/50/100/200,
      tope duro 300), máximo por artista, tags de género/mood, slider familiaridad↔descubrimiento,
      slider nicho↔popular, y selector **"basado en una playlist mía"** (D-11: solo playlists
      propias). Texto y parámetros son combinables, no excluyentes.
- [x] Aplicar los límites numéricos en código tras la respuesta (D-5): pedir ~30% de más, filtrar
      por máximo-por-artista, recortar al número exacto pedido.
- [x] Pedir nombre y descripción de la playlist **en la misma llamada** (sale gratis, no consume
      otra petición).
- [x] Matching a Deezer de cada `{title, artist}` sugerido, **reutilizando la cadena de fallback ya
      construida para importación CSV** (`playlist_import_export_service.dart`:
      `artist:"X" track:"Y"` → texto plano → solo título, con validación por duración). No
      reimplementar.
- [x] Vista previa: lista con portadas, +/- por canción (**edición local, sin coste**), y botón
      "afinar con IA" que sí gasta una petición reenviando el historial de turnos.
- [x] Al confirmar: insertar con el mismo flujo de la importación CSV (D-8).
- [x] Manejo de "no encontradas en Deezer": reportar cuáles no matchearon, como ya hace la
      importación (B6 del plan del buscador).

### 7.F.2 — Crear cola con IA

Entrada: botón en la **pantalla/hoja de cola**.

- [x] Toggle: cola **nueva** vs. **basada en la playlist/cola actual**.
- [x] Toggle: **intercalar** con la cola automática (1 sugerida cada ~3, el antiguo "Smart
      Shuffle") vs. **añadir como cola manual**. Ver H-8: el paso de intercalado terminó siendo
      adaptativo, no un "cada 3" fijo.
- [x] Dropdown de cantidad: 10 / 25 / 50 / 100 (tope 100). Por defecto **25**.
- [x] Atajo "✨ Mejorar esta cola" (D-9): prellena basada-en-cola-actual + intercalar + 25 y
      dispara directo, sin abrir el panel completo.
- [x] La cola manual **nunca** se toca (D-1).
- [x] Contexto: mandar la playlist/cola actual completa. **No hace falta resumir ni filtrar** salvo
      un tope de seguridad absurdo (>2.000-3.000 pistas), donde se muestrean los artistas/géneros
      más frecuentes.

### 7.F.3 — Modificar playlist con IA

Entrada: opción en el menú de 3 puntos de la playlist.

- [x] **Modo quitar:** se manda la playlist completa como `{id, title, artist}`; el schema
      restringe la salida a **IDs existentes** (D-7). Cero llamadas a Deezer. Vista previa con
      checkboxes premarcados antes de borrar.
- [x] **Modo agregar:** mismo flujo que 7.F.1, con la playlist actual como contexto. Tope 100 por
      operación.
- [x] Ambos modos terminan en vista previa confirmable; el `DELETE`/`INSERT` lo hace el cliente
      (D-12).

### 7.F.4 — Buscar canción por fragmento de letra

Entrada: botón más junto a "Popular" y "Búsqueda profunda" en el buscador
(`search_screen.dart:148` tiene el patrón del toggle).

- [x] El usuario pega un fragmento de letra; la función devuelve las coincidencias más probables
      con schema `{songs: [{title, artist}]}`.
- [x] Cada resultado se busca en Deezer y se muestra **como un resultado de búsqueda normal**, con
      portada y todo, para que el usuario pueda reproducir/agregar sin fricción.
- [x] Empty state propio ("no identificamos ninguna canción con ese fragmento").

---

## Fase 7.H — Límite de cuentas (250)

> Contexto y justificación del número: Documento Maestro §4.5. Proyecto sin fines de lucro,
> sin presupuesto, sostenido en planes gratuitos; el techo del free tier de Supabase es
> ~340 usuarios típicos a 10 años, y 250 deja margen para la incertidumbre de la estimación.

- [x] **7.H.1** Migración SQL: tabla de configuración de una sola fila (ej. `app_config`) con
      `max_accounts INTEGER` (valor inicial **250**). **No hardcodear el tope** — la gracia es
      poder subirlo con un `UPDATE` desde el dashboard sin tocar código ni redesplegar.
- [x] **7.H.2** Implementar el Auth Hook **"Before User Created"** que cuenta `auth.users` y
      rechaza el registro si `count >= max_accounts`. Puede ser una función de Postgres (más
      simple, sin deploy aparte) o una Edge Function. **Recomendación: función de Postgres**, ya
      que solo necesita contar filas y no hay razón para pagar el arranque de una Edge Function.
- [x] **7.H.3** Configurar el hook en el dashboard de Supabase (Authentication → Hooks). Es
      configuración de proyecto, **no** viaja en las migraciones — documentado el paso en
      `docs/fases/fase_7_h.md` para no perderlo si se recrea el proyecto.
- [x] **7.H.4** Manejo del rechazo en el cliente (`auth_screen.dart`): mensaje amigable
      explicando que las cuentas con nube están llenas. No un error genérico ni un "inténtalo más
      tarde". **Botón directo a "usar sin cuenta" (7.I) deliberadamente diferido**: 7.I no existe
      todavía en el código en este punto de la fase, así que no hay destino real al que apuntar —
      se cablea en 7.I.3. Ver nota en `auth_screen.dart` y en `docs/fases/fase_7_h.md`.
      ⚠️ **Bug conocido de la plataforma:** al rechazar con mensaje personalizado, el hook puede
      devolver `"Invalid payload sent to hook"` genérico en vez del texto propio (issue abierto de
      Supabase). El cliente **reconoce también ese error genérico** como "cupo lleno"
      (`looksLikeAccountLimitError`).
- [x] **7.H.5** El hook (contrato de Supabase Auth Hooks, verificado contra la documentación
      agosto 2026) se aplica tanto a correo/contraseña como a OAuth por diseño de la plataforma.
      Del lado del cliente, ambos caminos de registro reconocen el rechazo: correo/contraseña vía
      `AuthException` en `_handleSubmitForm`, y Google OAuth en **ambas** plataformas —
      `DesktopAuthService`/Windows y, tras un hallazgo real de la revisión independiente, también
      Android/iOS (el resultado de OAuth ahí llega por un deep link fuera de `auth_screen.dart`;
      ver `auth_deep_link_errors.dart`). **Pendiente de todos modos probar contra un proyecto real**
      (no automatizable sin un Supabase real) — ver pasos manuales en `docs/fases/fase_7_h.md`.
- [x] **7.H.6** Documentado en `docs/fases/fase_7_h.md` el detalle de implementación y los pasos
      manuales para el desarrollador; la operación día a día ya vivía en la sección "Operación: ver
      y administrar cuentas" al final de este documento.

---

## Fase 7.I — Modo local / sin cuenta

> Documento Maestro §4.6. Disponible **desde el lanzamiento** (D-23), no solo cuando el cupo se
> llene. Hallazgos de código relevantes: **H-5** (leer antes de empezar).

### Qué funciona y qué no

| Funciona sin cuenta | No funciona sin cuenta |
| :--- | :--- |
| Reproducción, búsqueda y descubrimiento (Deezer) | Sincronización entre dispositivos |
| Playlists, álbumes guardados, "Me gusta" (solo Drift) | Compartir playlists públicamente |
| Descargas offline (Fase 6) | Las 4 funciones de IA (7.F) — la Edge Function necesita el JWT |
| Auto-skip, crossfade, radio/cola infinita (7.B, es puro Deezer) | Respaldo en la nube (si se pierde el dispositivo, se pierde todo) |
| Importación / exportación CSV | |
| Estadísticas **locales** (ver 7.I.6) | |

### Sesión y navegación

- [x] **7.I.1** Concepto de sesión local: un `localModeProvider` (`Notifier<bool>`) que indica que
      el usuario eligió trabajar sin cuenta. **Desviación del plan:** persistido con
      `flutter_secure_storage` (`LocalModeStorage`), no `shared_preferences` -- el proyecto no
      tiene esa dependencia y ya usa `flutter_secure_storage` desde 7.E.8 para lo mismo (BYOK), sin
      motivo para agregar un paquete nuevo solo para dos strings. Precargado en `main.dart` antes
      de `runApp` para estar disponible de forma síncrona (el `redirect` de GoRouter no puede
      esperar un `FutureProvider`). Sobrevive reinicios (7.I.15).
- [x] **7.I.2** `app_router.dart`: el redirect a `/auth` pasa de `currentUser == null` a
      `currentUser == null && !isLocalMode`, extraído como función pura `computeAuthRedirect` para
      poder testearlo (7.I.12).
- [x] **7.I.3** `auth_screen.dart`: botón **"Usar sin cuenta"** con la explicación honesta pedida
      por el plan, visible junto al botón, no como letra chica.
- [x] **7.I.4** Avatar y perfil en modo local: semilla local generada una sola vez
      (`LocalModeStorage.getOrCreateAvatarSeed`, 16 bytes aleatorios en hex -- sin agregar el
      paquete `uuid`, que solo llega transitivamente hoy). Usada en `settings_screen.dart`,
      `home_screen.dart`, `app_shell.dart` y el selector de avatar
      (`avatar_selector_sheet.dart`, que antes caía siempre a un `'default'` genérico sin
      `userId`).

### Neutralizar la nube (sin romper el código existente)

- [x] **7.I.5** **Desviación deliberada del plan:** se evaluó cortar en `SyncService` como sugería
      el plan, pero sus métodos públicos (`syncLibrary`, `syncPlaylistDetail`,
      `syncListeningHistory`) no tienen forma barata de distinguir "modo local" de "entorno de
      test" sin inyectar estado nuevo -- agregar ese chequeo rompía los tests existentes de
      `sync_service_test.dart`, que los llaman directamente con repos mockeados. Se cortó en su
      lugar en los puntos de disparo de la UI (`library_screen.dart` initState + pull-to-refresh,
      `album_detail_screen.dart` botón de sync + pull-to-refresh); `playlist_detail_screen.dart`
      no necesitó cambios, sus llamadas a `syncPlaylistDetail` ya estaban gateadas por `remoteId
      != null`, que en modo local nunca se cumple. Los 14 archivos que usan `Supabase.instance` se
      revisaron uno por uno (detalle en `docs/fases/fase_7_i.md`) -- los repositorios ya tenían
      guardas de nulo (H-5) que hacen inofensivo cualquier resquicio no cubierto explícitamente.
- [x] **7.I.6** **Decidido: opción (a).** En modo local solo hay Semanal y Mensual (sobre
      `listening_history` crudo de Drift, que ya existe). Anual y "Desde el inicio" quedan como
      funciones exclusivas de cuenta — el modo local no tiene rollup mensual propio ni replica en
      Dart la agregación de `pg_cron`/Supabase; una sola implementación de la agregación, sin
      riesgo de que diverjan dos versiones con el tiempo.
      `listening_history` en Drift **no se poda** en modo local (la poda de 90 días es de
      Supabase, aquí no aplica) — aceptado explícitamente: a ~40 escuchas/día son ~2 MB/año,
      insignificante incluso a 10 años. No requiere ninguna tarea de limpieza.

### UI y gating de edición

- [x] **7.I.7** **Refactor central (H-5):** gating de edición de `isConnected` a `canEdit =
      isLocalMode || isConnected` (`computeCanEdit`, función pura testeada en 7.I.14) en
      `library_screen.dart` (crear playlist, menú de opciones: editar nombre, eliminar). Los
      puntos que el plan listaba en `playlist_detail_screen.dart`/`album_detail_screen.dart`
      resultaron no existir realmente -- ninguno de los dos usa `isConnectedProvider`, ya operan
      100% local con el patrón de mutación remota best-effort existente desde antes de esta fase.
- [x] **7.I.8** Ocultadas (no deshabilitadas) en modo local: "Hacer pública/privada", "Copiar
      enlace", las 4 entradas de IA (`library_screen.dart`, `queue_view.dart` x2,
      `search_screen.dart`), y los controles de sincronización manual (ícono + pull-to-refresh) en
      `library_screen.dart`/`album_detail_screen.dart`. "Cerrar sesión" también se oculta en el
      popup de perfil de escritorio (`app_shell.dart`).
- [x] **7.I.9** `settings_screen.dart`: "MI CUENTA" se reemplaza por un bloque "MODO LOCAL"
      (`_LocalModeSection`) que explica el estado, advierte que no hay respaldo, y ofrece "Crear
      cuenta y subir mi biblioteca". La sección de IA (BYOK) también se oculta en modo local.
- [x] **7.I.10** Migración local → cuenta (D-25, one-way) implementada en
      `PlaylistImportExportService.migrateLocalPlaylistsToAccount` +
      `migrateLocalSavedAlbumsToAccount`, disparada desde `auth_screen.dart` cuando se detecta una
      sesión nueva estando en modo local. Casos cubiertos tras la revisión independiente (ver
      `docs/fases/fase_7_i.md` para el detalle de los 3 hallazgos P0 corregidos): fallo a mitad de
      subida sin duplicar (reutiliza por título/`getOrCreateLikedPlaylist`), álbumes guardados
      (se perdían en el primer sync post-cuenta si no se migraban también), y modo local "pegado"
      tras un crash a mitad de migrar (autocorrección en `main.dart` al siguiente arranque). El
      caso "cupo lleno entre que abrió la pantalla y confirmó" no aplica: el tope de 250 cuentas
      (7.H) gatea la creación de la CUENTA, no la de playlists dentro de una cuenta ya creada.
- [x] **7.I.11** Visibilidad del export CSV en modo local: el botón ya existía sin gating alguno en
      `playlist_detail_screen.dart` desde antes de esta fase (funciona igual con o sin cuenta) --
      el bloque "Modo local" de Configuración (7.I.9) lo menciona explícitamente como respaldo.

### Tests

- [x] **7.I.12** `test/core/navigation/auth_redirect_test.dart` -- `computeAuthRedirect`, extraído
      del `redirect:` de GoRouter específicamente porque el `redirect` real se salta por completo
      en entorno de test (`isTestEnv`), así que sin la extracción esta lógica nunca se había
      ejercitado en ningún test del proyecto.
- [x] **7.I.13** Sin test dedicado nuevo -- la garantía viene de (a) los guardas de nulo
      preexistentes en los repositorios (H-5) y (b) los puntos de disparo de UI gateados
      explícitamente por `isLocalMode` (7.I.5), verificable por inspección del diff. No se armó un
      harness de widget test nuevo para `LibraryScreen` (no existía ninguno antes de esta fase)
      dado el costo de levantarlo contra el alcance ya grande de 7.I.
- [x] **7.I.14** `test/features/auth/local_mode_provider_test.dart` -- `computeCanEdit`, incluido
      el caso exacto que este ítem pedía cubrir (modo local + sin conexión -> `true`).
- [x] **7.I.15** `test/features/auth/local_mode_provider_test.dart` -- contrato de persistencia
      contra un `LocalModeStorage` en memoria (mismo patrón que los tests de `AiKeyStorage`: el
      proyecto no testea `flutter_secure_storage` real contra el canal de plataforma).
- [x] **7.I.16** `test/features/library/playlist_migration_test.dart` -- reintento sin duplicar,
      dedup de "Tus me gusta" contra una cuenta existente, reutilización por título tras un fallo
      parcial, y migración de álbumes guardados.

---

## Fase 7.G — Estadísticas y Wrapped

### Fuentes de datos (D-17)

| Vista | Fuente | Ventana |
|---|---|---|
| Semanal | `listening_history` (crudo) | Últimos 7 días |
| Mensual | `listening_history` (crudo) | Últimos 30 días |
| Anual | `user_stats_monthly` (agregado) | Últimos 12 meses (ventana móvil) |
| Desde el inicio | `user_stats_monthly` (agregado) | Todo el historial disponible |

`user_stats_monthly` **no** alimenta la vista "Mensual" de la UI. Su único propósito es sobrevivir
más allá de los 90 días de retención del historial crudo, para poder calcular Anual y
Desde-el-inicio. (Usarla para "Mensual" mostraría el último mes **cerrado** — en agosto verías
julio, justo cuando el usuario espera lo más reciente.)

### Contenido de cada vista

| Vista | Contenido |
|---|---|
| Semanal | Minutos totales, top 5 artistas, top 5 canciones (con nº de reproducciones) |
| Mensual | Minutos totales, top 5-10 artistas, top 5-10 canciones, **top 5 géneros** |
| Anual (Wrapped) | Minutos totales, top 10 artistas, top 10 canciones, top géneros, mes más activo. Tarjetas tipo stories |
| Desde el inicio | Minutos totales, top artistas, top canciones, top géneros. **Bajo demanda** (botón), puede tardar |

### Tareas

- [x] **7.G.1** Migración SQL: tabla `user_stats_monthly` (usuario + mes) con minutos totales,
      **top 50 artistas con sus minutos**, **top 50 canciones con sus minutos**, y todos los
      géneros. Guardar `{id, minutos}` en JSONB — **no** nombres ni portadas (eso se resuelve con
      el caché de metadata de Deezer que ya existe), lo que mantiene la fila en ~4 KB.
      El top 50 es lo que permite un Anual razonablemente preciso al sumar 12 meses; se acepta el
      margen de error de un artista que quede fuera del top 50 de algún mes (invisible para el
      usuario en una función de este tipo).
- [x] **7.G.2** Cron mensual con `pg_cron`: agregar el mes recién cerrado a `user_stats_monthly`
      y **después** podar `listening_history` a >90 días. **El orden importa** — nunca al revés.
- [x] **7.G.3** Queries de agregación para Semanal y Mensual sobre datos crudos (misma query,
      distinta ventana).
- [x] **7.G.4** Rollup de Anual (suma de las últimas 12 filas) y Desde-el-inicio (suma de todas).
- [x] **7.G.5** Pantalla de Estadísticas con 3 pestañas (Semanal / Mensual / Anual) + acción
      "Desde el inicio". Empty states para usuarios sin historial suficiente, y loading states
      tipo skeleton (Documento Maestro §10, antipatrón 3).
- [x] **7.G.6** Entrada desde **Inicio**: tarjeta de estadísticas resumidas ("Tus minutos esta
      semana: X — Ver más"). Ya estaba prevista en el Documento Maestro §2.1.1
      ("estadísticas resumidas" en contenido destacado).
- [x] **7.G.7** Tarjetas imprimibles tipo stories: renderizar con `RepaintBoundary.toImage()` y
      compartir con `share_plus`. **Solo exportar imagen** (D-20), sin URL pública.
- [x] **7.G.8** Tests de las agregaciones: umbral de escucha, ventanas de 7/30 días, suma correcta
      de 12 meses, caso de usuario con menos de 12 meses de historial (D-18).

---

## Escalabilidad de Estadísticas (estimación)

Con ~4 KB por fila mensual (top 50 artistas + top 50 canciones + géneros en JSONB, guardando solo
`{id, minutos}`), **sin podar nunca** (D-19):

| Usuarios | Historial | Espacio de `user_stats_monthly` |
|---|---|---|
| 100 | 10 años | ~48 MB |
| 1.000 | 5 años | ~240 MB |
| 1.000 | 10 años | ~480 MB |
| 10.000 | 1 año | ~480 MB |

El límite del plan gratuito de Supabase (500 MB) cubre **toda** la base, no solo esta tabla. El
punto donde esta tabla empieza a doler (~10.000 usuarios) coincide con el punto donde el
Documento Maestro §4 ya prevé subir al plan Pro ($25/mes, 8 GB) por el límite general — no es un
problema nuevo ni exclusivo de Estadísticas.

⚠️ Es una estimación con supuestos razonables, **no una medición**. Conviene revisar el tamaño real
de la tabla tras unos meses en producción en vez de confiar en el número.

---

## Operación: ver y administrar cuentas (para el desarrollador)

Todo se hace desde el **dashboard de Supabase**, sin necesidad de tocar la app.

**Ver cuántas cuentas hay y quiénes son:**
- Dashboard → **Authentication → Users**. Lista todos los usuarios con su correo, proveedor
  (Google / email), fecha de registro y último acceso. El total aparece en la propia vista.
- Alternativa exacta, desde **SQL Editor**:
  ```sql
  SELECT COUNT(*) FROM auth.users;
  ```

**Borrar una cuenta de prueba:**
- Dashboard → Authentication → Users → menú (⋯) de la fila → **Delete user**.
- El borrado **libera cupo automáticamente**, porque el hook cuenta filas vivas de `auth.users`
  en cada registro, no un contador acumulado.
- ✅ **Los datos asociados se borran solos:** todas las tablas del esquema usan
  `REFERENCES auth.users(id) ON DELETE CASCADE`
  (`20250001000000_initial_schema.sql`), así que al borrar el usuario se van con él sus playlists,
  pistas, álbumes guardados e historial. No hay limpieza manual que hacer.

**Cambiar el tope de cuentas** (sin redeploy, gracias a 7.H.1):
```sql
UPDATE app_config SET max_accounts = 300;
```

**Vigilar el consumo real** (recomendado cada cierto tiempo, ver Documento Maestro §4.4):
- Dashboard → **Reports / Database** para el tamaño de la BD y el **egress** — este último es el
  recurso que hoy no tenemos modelado con confianza y conviene mirar con datos reales.

---

## Pruebas de la matriz (`matriz_de_pruebas.md`, Fase 7)

Ya definidas en la matriz, cubiertas por este plan:

- **Automatizado:** algoritmo de reordenamiento de cola (7.A.13) · tests de Edge Functions con
  mocks (7.E.9) · flujo BYOK: la función recibe `X-User-AI-Key`, la usa, no la guarda ni la
  loguea (7.E.9)
- **Humano:** arrastrar y soltar en la cola (7.A.10) · ingresar texto en el buscador IA (7.F.4) ·
  activar crossfade en pista descargada en Windows **y** en Android (7.D.6)

Conviene ampliar la matriz con casos nuevos surgidos de este plan: cola manual sobrevive a cambios
de shuffle/playlist, "anterior" tras pista manual, radio infinita con playlist de 1 solo artista,
guard de cascada de auto-skip, y vista previa de IA que se cancela sin escribir nada.
