# Quinta ronda de correcciones (post-Fase 8)

Sesión del 2026-10-03. Plan, diagnóstico y estado. Cada bundle cierra con `flutter analyze` limpio,
los tests del área en verde, commit y push.

## Diagnóstico previo (leyendo código y la API en vivo)

- **H-R5-1. Crossfade en skips manuales.** `_playCurrentGuarded` decide el crossfade solo con
  "ajuste > 0, pista actual y nueva descargadas, motor sonando". No sabe si la transición vino del
  fin natural de la pista o de un botón, así que "siguiente"/"anterior"/tocar otra canción también
  cruzaban.
- **H-R5-2. "Siguiente" muerto mientras carga.** `skipToNext` sostiene `_isTransitioning` durante
  toda la extracción (2-3 s). El segundo toque sale por el guard. La mutación de la cola es
  síncrona; lo único lento es la carga, que ya se descarta sola por `_playGeneration`.
- **H-R5-3. Ícono de play durante la búsqueda/match.** Entre el `stop()` del motor y el `setUrl`
  el motor está en `idle`. El adaptador del SO ya publica `loading` en esa ventana
  (`isPreparingPlayback`), pero la UI no la ve: solo pinta el spinner cuando el motor bufferiza.
- **H-R5-4. Portadas de descargas.** `CoverCacheService` borra archivos de portada al pasar de 200
  descargas (índice LRU pensado como caché, pero esa carpeta son las portadas de las descargas), y
  si un archivo local no se puede decodificar `TrackCoverImage` muestra el hueco sin intentar la
  red.
- **H-R5-5. Portadas que fallan en grupo solo en móvil.** No reproducible desde el PC (46 portadas
  en ráfaga, todas 200). Hipótesis más fuerte: conexiones HTTP reutilizadas que la red móvil ya
  cerró (el NAT de la red mata conexiones ociosas; `HttpClient` las reusa hasta 15 s) — fallan en
  grupo todas las que salen juntas. Las recomendaciones al pie de la playlist usan
  `CachedNetworkImage` sin ningún reintento.
- **H-R5-6. Deezer `/artist/{id}/top` devuelve `{"data":[],"total":0}`** (probado el 2026-10-03
  desde México con varios artistas; `/radio`, `/albums` y `/search/playlist` sí responden).
- **H-R5-7. Teclado trabado en hojas con campo de texto.** Con una hoja abierta, el `Scaffold` del
  shell sigue redimensionando su cuerpo en cada frame de la animación del teclado, y cada asa de
  arrastre de la cola lee `MediaQuery.of` (se reconstruye con cualquier cambio).
- **H-R5-8. Los dos sliders de "Crear playlist con IA" son casi el mismo eje.** `familiarity` 0 =
  "mainstream" y `popularity` 1 = "éxitos masivos"; el prompt solo los distingue en un matiz.

## Bundles

1. **Reproductor:** H-R5-1, H-R5-2 (guard solo durante la mutación de la cola + extracciones de
   streaming que se reemplazan entre sí), H-R5-3 (estado `preparing` visible en la UI) y portada
   de la siguiente pista precargada.
2. **Cola:** "Mejorar cola" rápida sin IA (radio de Deezer intercalada, estilo Smart Shuffle) y
   "Crear cola con IA" simplificada que mete el resultado en la cola manual. H-R5-7.
3. **Portadas:** H-R5-4, H-R5-5 (servicio HTTP propio con reintento y conexiones ociosas cortas,
   recomendaciones con `TrackCoverImage`, logs de diagnóstico).
4. **Letras:** tamaño animado por escala (sin reflujo ni cambio de alineación) y desplazamiento
   libre con botón "Sincronizar".
5. **Gestos:** deslizar para encolar desde toda la fila, recorrido máximo de media pantalla,
   umbral al 30 % con vibración, al soltar vuelve a su sitio (patrón de Spotify).
6. **Rendimiento:** playlists grandes, toque que reproduce al frenar el scroll, cambio de pestaña,
   barra de desplazamiento rápido en móvil.
7. **Pulido de UI:** tooltips de Windows, "Búsquedas recientes", color del toast, "Eliminar
   descarga", botón de radio del artista.
8. **Catálogo Deezer:** "Esto es {artista}", más playlists en Inicio, buscar playlists de Deezer,
   respaldo para H-R5-6.
9. **Límites:** caracteres de nombres/descripciones y 10 000 canciones por playlist (app + BD).
10. **IA:** un solo control en lugar de los dos sliders (H-R5-8).
11. **Android Auto.**
12. **README** y documentación.

## Estado

En curso.
