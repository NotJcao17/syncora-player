# Syncora Player — Fase 6: Registro de Correcciones y Pulido Final

## 📋 Resumen de Ajustes Técnico-Arquitectónicos

Este documento registra todas las correcciones, salvaguardas y optimizaciones implementadas durante la fase de QA y pruebas finales de la **Fase 6 (Motor Offline y Descargas Masivas)**.

---

## 🛠 Detalle de Correcciones

### 1. Corrección de Inserción / Actualización SQLite en Android (`DownloadedTrackDao`)
- **Problema**: Violación de restricción de clave primaria (`ON CONFLICT("id")`) al intentar re-descargar o actualizar el estado de una pista registrada en SQLite.
- **Solución**: Se reemplazó la consulta directa por una comprobación previa con `getByTrackId(trackId)`. Si la pista existe se ejecuta `update().write()`, y de lo contrario se realiza `into().insert()`.

### 2. Gestión Inteligente de Diálogos y Hojas Modales (`AppBottomSheet.pop`)
- **Problema**: `Navigator.of(context, rootNavigator: true).pop()` en Android desapilaba la última página del Scaffold dejando la pantalla negra (`You have popped the last page off of the stack`). En PC, desapilaba la ruta de GoRouter redirigiendo la navegación a `/library`.
- **Solución**: Se creó la función centralizada `AppBottomSheet.pop(context)` que detecta dinámicamente si el entorno es escritorio o móvil:
  - **PC (>=720px)**: Usa `Navigator.of(context, rootNavigator: true).pop()` para cerrar únicamente la ventana modal `Dialog`.
  - **Móvil (<720px)**: Usa `Navigator.of(context).pop()` comprobando `canPop` para cerrar únicamente la hoja deslizable `showModalBottomSheet`.

### 3. Inyección de Cabeceras HTTP en Descargas de YouTube (`DownloadService`)
- **Problema**: YouTube denegaba peticiones de descarga con respuestas `HTTP 403 Forbidden` al no recibir las cabeceras HTTP de extracción.
- **Solución**: Se configuraron las cabeceras extraídas (`headers`) en el objeto `HttpClientRequest` dentro de `DownloadService`.

### 4. Reubicación del Ícono de Descarga en Lista de Canciones (`TrackTile`)
- **Problema**: En dispositivos móviles con títulos de canciones largos, el ícono vectorial de descargado se cortaba o desalineaba al estar colocado a la derecha del título.
- **Solución**: Se movió el ícono de estado de descarga (`⬇`, indicador de progreso o sin conexión) a la línea de subtítulo, **ubicándolo justo antes del nombre del artista** (ej. `⬇ Artista`). Esto otorga el 100% del ancho al título en la primera línea.

### 5. Escaneo Iterativo para Salto Silencioso Offline (`SyncoraPlayerController._skipSilently`)
- **Problema**: Al estar offline y reproducir una cola con 2 o más canciones consecutivas no descargadas, el salto silencioso recursivo quedaba bloqueado por la bandera `_isTransitioning`, dejando la reproducción pausada en la segunda pista.
- **Solución**: Se reescribió `_skipSilently()` utilizando un **bucle iterativo `while (true)`** que recorre la cola síncronamente hasta encontrar la primera canción con audio local disponible, eliminando la recursión.

### 6. Limpieza Automática de Descargas Interrumpidas (`DownloadService.cleanupInterruptedDownloads`)
- **Problema**: Si la app se minimizaba o se cerraba forzadamente durante una descarga activa, quedaban archivos `.mp4` incompletos o corruptos en el almacenamiento.
- **Solución**: Se implementó `cleanupInterruptedDownloads()`, ejecutado en la inicialización de `downloadServiceProvider`. Elimina de forma transparente cualquier archivo `.mp4` incompleto o de 0 bytes del disco y limpia los registros de la base de datos local.

---

## 📑 Estado Final de la Fase 6
- **Estado**: 100% Completado y Verificado.
- **Tests Automatizados**: 71/71 tests pasados (`flutter test`).
- **Análisis Estático**: 0 Errores (`flutter analyze`).
- **Repositorio Git**: Cambios commiteados y pusheados a la rama `master`.
