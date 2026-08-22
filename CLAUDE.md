# Instrucciones para agentes en este repositorio

Antes de trabajar en cualquier tarea, leer **`docs/Documento_Maestro.md`** completo — es la fuente
de verdad de arquitectura, stack, metodología de trabajo y reglas del proyecto. No es opcional. Es el documento inicial, así que pudo haber sufrido cambios, pero estarían documentados en los documentos de fase.

## Reglas de Git (estrictas — ver Documento_Maestro.md, sección 1)

- Los commits llevan **solo mensaje/subject, sin cuerpo ni descripción extendida**.
- **Nunca** agregar `Co-authored-by` ni ninguna otra atribución de autoría del agente/IA a los commits.
- Al finalizar y validar cada fase de trabajo, el agente hace `git push` al remoto — no hace falta
  pedir confirmación para ese push normal (ya autorizado por esta regla). Esto **no** cubre
  operaciones destructivas o de reescritura de historia (`push --force`, `reset --hard`, etc.), que
  siempre requieren confirmación explícita del usuario en el momento, como en cualquier repo.

## Metodología de ejecución de la Fase 7 (orquestador + subagentes)

Mientras se ejecute `docs/plan_fase_7.md`, esta metodología aplica y **sobrevive a cualquier
`/compact` o sesión nueva** — si la memoria de la conversación se pierde, re-leer esta sección
y el plan basta para retomar sin perder nada importante:

- **Orden de fases:** estricto, el que define el plan (7.0 → 7.A → ... → 7.G). No reordenar ni
  paralelizar fases que dependen entre sí.
- **Un subagente por fase**, con contexto acotado a esa fase (no el plan completo).
- **Modelos:** Sonnet, effort high, para el orquestador y para **todas** las fases de
  implementación. **Excepción única:** la revisión de código independiente de las fases **7.A**
  (cola dual) y **7.I** (modo local) va en **Opus medium/high** — son las dos de mayor riesgo de
  regresión. El resto de las revisiones de código, en Sonnet.
- **Revisión independiente obligatoria** entre fases (subagente de `code-review` separado del que
  implementó), antes de dar la fase por cerrada.
- **Tests automatizados como gate de cada fase** — no pruebas manuales a medio camino; las
  manuales de `docs/matriz_de_pruebas.md` se agrupan al final de toda la Fase 7.
- **Marcar los checkboxes `[x]`** de `docs/plan_fase_7.md` a medida que se completan, y comitear
  seguido (no solo al cerrar la fase entera) — es la fuente de verdad de progreso, más confiable
  que la memoria de la conversación. Si aparece un hallazgo que cambia el plan, documentarlo ahí
  con el mismo formato de "hallazgo verificado" que ya usan H-1 a H-5, no aplicarlo en silencio.
- **Cuándo parar y preguntar al usuario:** decisión de diseño no cubierta por el plan, algo que
  una revisión de código no puede resolver con confianza, o cualquier acción destructiva/
  irreversible. Fuera de eso, seguir de fase en fase sin esperar aprobación en cada una.

### Estado actual (última actualización: 2026-08-21)

**Cerradas, commiteadas y pusheadas a `master`** (cada una con revisión independiente aplicada y
bugs encontrados corregidos — ver `docs/fases/fase_7_{0,a,b,c,d,e,f}.md` para el detalle de cada
una): **7.0, 7.A, 7.B, 7.C, 7.D, 7.E, 7.F.1**. Todas con `flutter analyze` limpio y la suite de
tests en verde en el momento de cerrarlas (296 tests al cerrar 7.F.1).

7.F.1 ("Crear playlist con IA") quedó con 3 bugs reales encontrados y corregidos por el
orquestador antes de la revisión (churn de suscripciones Drift por crear un `Stream` inline en
cada rebuild, un `Timer` interno de Drift que quedaba pendiente en tests sin
`closeStreamsSynchronously`, y `FlutterSecureStorage` real colgando un test por no mockear
`aiKeyStorageProvider`), más 4 hallazgos de la revisión independiente (Sonnet) ya corregidos: falta
de cobertura de test en el camino exitoso (agregada), doble-tap posible en "Crear con IA"
(agregado flag `_isSubmitting`), mensaje de validación que prometía más de lo que exigía (agregado
`_hasAnyParamSet`), y un carácter soft-hyphen suelto en `prompts.ts`. Detalle completo en
`docs/fases/fase_7_f.md`.

**Siguiente sub-bloque a implementar: 7.F.2 (crear cola con IA).** Ver su sección en
`docs/plan_fase_7.md`. Puede reusar bastante de lo construido en 7.F.1 (el widget de vista previa
de sugerencias, el matching contra Deezer, el patrón de inserción canónica) — revisar si conviene
extraer algo compartido antes de implementarlo, en vez de duplicar.

**Todavía no iniciadas:** 7.F.2, 7.F.3 (modificar playlist con IA), 7.F.4 (buscar por fragmento de
letra), 7.H (límite de cuentas), 7.I (modo local), 7.G (estadísticas). Orden no negociable: 7.I
antes que 7.G (ver plan).

**Hallazgos verificados durante la Fase 7 que no estaban en el plan original** (ya documentados
como H-6/H-7 en `docs/plan_fase_7.md`, sección de hallazgos — no volver a descubrirlos): el aviso
visual del guard 403/red de Fase 1 nunca tenía consumidor en la UI (arreglado en 7.C); el modelo
Gemini y la forma de llamar a su API cambiaron desde que se escribió el plan — usar
`gemini-3.5-flash-lite` sobre la API de Interactions (`v1beta/interactions`), no
`gemini-3.1-flash-lite`/`generateContent` (ya implementado así en 7.E).

**Pasos manuales acumulados, pendientes para el desarrollador humano** (ninguno bloquea seguir
implementando fases del cliente Flutter, pero si se quiere probar IA de verdad hacen falta):
aplicar la migración `20250001000008_ai_rate_limits.sql`, desplegar la Edge Function
(`supabase functions deploy ai-assistant`), configurar el secreto `GEMINI_API_KEY`, y correr
`deno test`/`deno check` sobre `supabase/functions/ai-assistant/` (Deno no está disponible en el
entorno del agente, esos tests nunca se ejecutaron, solo se escribieron). Detalle completo en
`docs/fases/fase_7_e.md`. También sigue pendiente 7.D.6 (prueba humana de crossfade en Windows y
Android, ver `docs/fases/fase_7_d.md`).

## Otros documentos relevantes

- `docs/plan_fase_7.md` — plan y decisiones de diseño de la **Fase 7** (cola dual, radio/cola
  infinita, funciones de IA con Gemini, auto-skip, crossfade, estadísticas Wrapped). Leer antes de
  tocar cualquier cosa de la Fase 7.
- `docs/plan_buscador_importacion_matcher.md` — plan y estado del buscador/importación/matcher de
  YouTube (Fases 0/A/B/C/D).
- `docs/fases/` — documentos de contexto y decisiones de arquitectura por fase.
- `docs/matriz_de_pruebas.md` — matriz de pruebas manuales que el humano ejecuta.
