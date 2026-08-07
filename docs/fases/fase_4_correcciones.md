# Syncora Player — Fase 4: Correcciones y Arquitectura Técnica

Este documento registra los ajustes técnicos y arquitectónicos aplicados durante la Fase 4 que son relevantes para las fases futuras (**Fase 5: Nube & Supabase**, **Fase 6: Motor Offline** y **Fase 7: Experiencia Premium & IA**).

---

## 1. Extracción y Matching de Audio (Deezer ➔ YouTube)

### Motor de Búsqueda y Coincidencia (`YtSearchMatcher`)
- Al reproducir pistas de Deezer (IDs numéricos), el reproductor resuelve el enlace a YouTube de 11 caracteres mediante `Innertube Search` dentro de un isolate de QuickJS (`ExtractionIsolate`).
- **`YtSearchMatcher`** analiza candidatos basándose en:
  - **Duración**: Comparación exacta contra la duración de Deezer ($\le 3\text{s} \to +100$, $> 30\text{s} \to -50$).
  - **Filtro de Calidad**: Penalización de covers, karaokes o remedos ($-80$) y bonificación a audios oficiales o VEVO ($+30$).
  - **Coincidencia de Artista**: Normalización de cadenas y acentos ($+50$).
- **Caché en Memoria**: La resolución resultante (`DeezerTrackId` ➔ `YoutubeVideoId`) se mantiene en memoria en `ExtractionIsolate` y se inyecta en el objeto `SyncoraTrack` en tiempo de ejecución.

### Optimización de Cold Start (< 2s)
- Se configuró `retrieve_player: false` en la inicialización de `Innertube` dentro de QuickJS.
- Al omitir la descarga del script ejecutable `base.js` (~3 MB), la resolución de URLs directas (`itag 18`) pasó de ~20 segundos a **< 300 ms**, logrando reproducción inicial en menos de 2 segundos.

### Resiliencia y Control de Superposición
- **Peticiones Canceladas (`ExtractionError.cancelled`)**: Si el usuario cambia de canción rápidamente antes de terminar la extracción previa, la petición anterior se marca como cancelada para no interrumpir la nueva pista.
- **Rampa de Volumen (Micro Fade-Out 150ms)**: Se aplica una atenuación de 150ms antes de cambiar de pista o detener el motor para evitar chasquidos o clics de audio.

---

## 2. Persistencia de Sesión y Contexto de Reproducción

- **`PlayerSessionStorage`**: Guarda localmente en JSON la cola de reproducción completa (`queue`), el índice actual (`currentIndex`), la posición en segundos (`positionSeconds`), el modo de repetición (`repeatMode`), el estado aleatorio (`shuffle`) y el contexto activo (`activeContextId`).
- **Restauración en Frío**: Al abrir la app, la sesión se restaura dejando el reproductor cargado en estado **pausado**, listo para reanudar desde el segundo exacto.
- **`activeContextId`**: Identificador de cadena (ejemplo: `'playlist_5'`, `'album_12'`) que rastrea la fuente desde donde se inició la reproducción, permitiendo sincronizar botones de cabecera e indicadores laterales.

---

## 3. Consideraciones de Entorno para Pruebas (`_isTestEnv`)

- Se implementó la guardia `_isTestEnv` en los controladores, fábricas de motor de audio, widgets animados y adaptadores del sistema operativo.
- Evita el lanzamiento de procesadores nativos de Windows (`SMTCWindows`), aislantes de extracción QuickJS o animaciones infinitas de shimmer durante la ejecución de pruebas automatizadas (`flutter test`).
- Mantiene la suite con **45/45 pruebas aprobadas** y **0 errores de análisis estático** (`dart analyze`).
