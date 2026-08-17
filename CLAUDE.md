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

## Otros documentos relevantes

- `docs/plan_buscador_importacion_matcher.md` — plan y estado del buscador/importación/matcher de
  YouTube (Fases 0/A/B/C/D).
- `docs/fases/` — documentos de contexto y decisiones de arquitectura por fase.
- `docs/matriz_de_pruebas.md` — matriz de pruebas manuales que el humano ejecuta.
