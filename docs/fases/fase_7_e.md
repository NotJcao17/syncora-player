# Syncora Player — Fase 7.E: Infraestructura de IA (Edge Function + BYOK)

## 📋 Resumen de la Fase
Infraestructura nueva desde cero (H-4): la Edge Function única que servirá de base a las 4
funciones de IA de la Fase 7.F, con autenticación por JWT, rate limiting, flujo BYOK unificado, y
los `response_schema` de las 5 acciones (D-6/D-7). **No implementa las pantallas ricas de las 4
funciones de IA** (paneles de parámetros, vista previa, matching contra Deezer) — eso es la Fase
7.F completa, construida sobre esta base.

> ⚠️ **Hallazgo H-7 (documentado en `docs/plan_fase_7.md`):** antes de implementar se verificó
> contra `ai.google.dev` en vivo que el plan original estaba desactualizado en dos puntos: el
> modelo pasó de `gemini-3.1-flash-lite` (ya con fecha de baja anunciada, mayo 2027) a
> `gemini-3.5-flash-lite`, y la API de Gemini migró de `generateContent` a la nueva "API de
> Interactions" (`v1beta/interactions`). La función se implementó contra la API vigente.
>
> ⚠️ **Revisión de código encontró y corrigió un problema de seguridad real** antes de cerrar la
> fase: la política RLS de `DELETE` sobre la tabla de rate limit permitía que cualquier usuario
> reseteara su propio límite llamando directamente al SDK de Supabase con su propio JWT, sin pasar
> por la Edge Function. Ver sección "Revisión" más abajo.

---

## 🏗 Componentes desarrollados

### 1. Edge Function (`supabase/functions/ai-assistant/`)
Una sola función (`index.ts`, `Deno.serve`) con routing por `action` — evita duplicar auth/rate
limit/BYOK/saneamiento cuatro veces. Módulos separados para poder testear lógica pura sin arrancar
el listener HTTP real:
- `actions.ts` — las 5 acciones soportadas (`create_playlist`, `create_queue`,
  `modify_playlist_remove`, `modify_playlist_add`, `lyric_search`).
- `gemini.ts` — cliente mínimo de la API de Interactions (`fetch` nativo, sin SDK npm), modelo
  fijado en una sola constante (`GEMINI_MODEL = "gemini-3.5-flash-lite"`).
- `schemas.ts` — `response_schema` por acción; `modify_playlist_remove` construye un `enum`
  dinámico con los ids recibidos en la petición (D-7: estructuralmente imposible que la IA invente
  un id a borrar), más una función de verificación de forma del lado del servidor (defensa en
  profundidad, nunca se confía ciegamente en que Gemini cumplió el schema).
- `prompts.ts` — instrucciones de sistema fijas por acción, texto controlado por el desarrollador,
  jamás construido concatenando texto del usuario.
- `sanitize.ts` — tope de longitud en texto libre (600 caracteres) y de items de contexto (3.000),
  más el empaquetado del prompt final con un bloque delimitado explícito
  (`<<<DATO_USUARIO>>>...<<<FIN_DATO_USUARIO>>>`) que instruye al modelo a tratar ese bloque como
  dato a analizar, nunca como instrucción nueva, sin importar lo que diga.
- `validate_request.ts` — parseo/normalización del body por acción, con sus propios topes por
  acción (D-5: ~30% de margen sobre los topes de UI de 7.F).
- `rate_limit.ts` — ver sección de revisión abajo.
- `response_helpers.ts` / `errors.ts` — mapeo de errores de Gemini a los 9 códigos diferenciados
  (`AiErrorCode`), nunca un 500 genérico para un caso esperado.

### 2. Migración SQL (`supabase/migrations/20250001000008_ai_rate_limits.sql`)
Tabla `ai_rate_limit_requests`: registro de eventos (una fila por petición aceptada con la llave
compartida), no un contador de ventana fija — da una ventana deslizante real de 1 hora sin el
efecto de "doble cupo" en el borde entre ventanas.

### 3. Rate limit (7.E.3)
20 llamadas/hora por usuario para la llave compartida (justificación numérica documentada en
`rate_limit.ts`: ~1.000 RPD compartidos entre todos, 20/hora es generoso para una sesión intensa
sin permitir que un solo usuario agote la cuota diaria por su cuenta). Se omite por completo en
modo BYOK. Falla **abierto** (permite la petición) si la consulta al límite falla — es protección
contra abuso, no una garantía dura de cuota exacta.

### 4. Cliente Dart y BYOK
- `lib/data/services/ai_assistant_service.dart` — `AiAssistantService`, `AiAction`, `AiErrorCode`
  (enum tipado 1:1 con los códigos del servidor), `AiAssistantException`. Invoca la función vía
  `supabase_flutter`, adjunta `X-User-AI-Key` si hay llave BYOK guardada.
- `lib/data/services/ai_key_storage.dart` — `SecureAiKeyStorage` sobre `flutter_secure_storage`
  (paquete nuevo, agregado a `pubspec.yaml`). La llave nunca toca un provider en memoria plano ni
  la base de datos.
- Sección "Inteligencia Artificial" nueva en `settings_screen.dart`: campo BYOK, guardar/borrar,
  enlace a AI Studio.

---

## 🔎 Revisión de código y hallazgo de seguridad corregido

Se revisó directamente (sin agentes adicionales, dado el alcance acotado y la calidad ya alta del
código) toda la superficie de seguridad crítica: auth JWT, manejo de la llave BYOK, saneamiento
anti-inyección, y el rate limit.

**Hallazgo real (corregido):** la primera versión de la migración le daba a cada usuario permiso
RLS de `DELETE` sobre sus propias filas de `ai_rate_limit_requests`, pensado para que la Edge
Function podara filas viejas usando el JWT del usuario (nunca `SERVICE_ROLE_KEY`). Esa misma
política le daba el permiso también al **cliente directamente** — cualquier usuario autenticado
podía llamar al SDK de Supabase con su propio JWT y borrar su historial de peticiones a voluntad,
saltándose el rate limit por completo sin tocar la Edge Function.

**Fix:** se eliminó la política de `DELETE` (y el `UPDATE` nunca existió) — la tabla ya no se poda
ni desde el cliente ni desde la función. La corrección del límite no depende de la poda
(`checkRateLimit` ya filtra por `requested_at > windowStart`), así que esto no afecta la
correctitud, solo el tamaño de la tabla con el tiempo. La poda queda documentada como pendiente de
un futuro job `pg_cron` con privilegios de servidor (mismo patrón que usará la Fase 7.G) — no
implementado todavía. Con el tope de 250 cuentas (7.H) y 20 peticiones/hora, el crecimiento sin
podar es manejable durante varios meses.

---

## 📑 Verificación de pruebas

- `flutter analyze`: limpio (solo lints `info` preexistentes).
- `flutter test`: **287 tests, 0 fallos**, incluidos 11 nuevos del cliente Dart
  (`test/data/services/ai_assistant_service_test.dart`): header `X-User-AI-Key` se adjunta solo
  cuando hay llave guardada, los códigos de error se distinguen correctamente.
- **Tests de Deno** (`sanitize_test.ts`, `schemas_test.ts`, `validate_request_test.ts`,
  `errors_test.ts`, `rate_limit_test.ts`, `response_helpers_test.ts`): escritos cubriendo la lógica
  pura de cada módulo, pero **no se pudieron ejecutar** — Deno CLI no está instalado en este
  entorno (verificado). Quedan sin verificar hasta que el desarrollador corra `deno test`/
  `deno check` localmente.

---

## ⚠️ Pasos manuales pendientes (desarrollador humano)

1. `supabase db push` (o aplicar `20250001000008_ai_rate_limits.sql` manualmente).
2. `supabase functions deploy ai-assistant`.
3. `supabase secrets set GEMINI_API_KEY=...` (obtener la llave en AI Studio).
4. Confirmar `gemini-3.5-flash-lite` sigue vigente y sus límites RPM/RPD/TPM exactos contra AI
   Studio antes de confiar en el número de 20/hora del rate limit interno — no se verificaron
   cifras exactas del free tier para este modelo específico en esta sesión (H-7).
5. Correr `deno check` y `deno test` sobre `supabase/functions/ai-assistant/` localmente antes de
   confiar en esa cobertura.
6. Build limpio de Android/Windows para que `flutter_secure_storage` termine de registrarse
   nativamente (ya se corrió `flutter pub get`).
