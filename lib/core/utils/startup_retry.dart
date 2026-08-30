import 'dart:async';
import 'dart:io';

/// Presupuesto de reloj por defecto para los reintentos de arranque.
///
/// El problema real que resuelve: en el arranque en frío de Android la pila de
/// red tarda unos segundos en resolver DNS, y esos fallos son **instantáneos**
/// (`Failed host lookup` vuelve en milisegundos, no espera al `connectTimeout`
/// de Dio). Con el esquema anterior — 3 intentos con esperas de 600 ms y
/// 1200 ms — los tres se gastaban en menos de **2 segundos** y la pantalla de
/// Inicio se quedaba con "No pudimos cargar el contenido" hasta que el usuario
/// pulsaba Reintentar, aunque la conexión fuera perfecta. En dispositivos que
/// tardan más de 2 s en tener DNS, eso pasaba en *todos* los arranques.
///
/// Contar el presupuesto en tiempo de reloj (y no en número de intentos) es lo
/// que hace que el arreglo no dependa de adivinar cuánto tarda un fallo.
const Duration startupRetryBudget = Duration(seconds: 15);

/// Tope de espera entre intentos: sin él, el backoff exponencial se comía todo
/// el presupuesto en dos esperas largas en vez de repartirlo en varios
/// intentos.
const Duration startupRetryMaxDelay = Duration(seconds: 2);

/// Reintenta [action] cuando falla por un problema de red *transitorio*.
///
/// Solo reintenta fallos de red. Cualquier otro error se relanza tal cual: un
/// 404 o un error de parseo no mejora por repetirlo, y enmascararlo escondería
/// bugs reales.
///
/// Parámetros de corte, en orden de prioridad:
///
/// - [shouldRetry]: si devuelve `false`, se relanza de inmediato sin esperar
///   nada más. Se usa para pasar "¿hay interfaz de red?" — estando offline de
///   verdad no tiene sentido quemar el presupuesto entero antes de decírselo
///   al usuario, y así el mensaje de "Sin conexión" sigue siendo inmediato.
/// - [maxElapsed]: presupuesto total de reloj desde la primera llamada.
/// - [attempts]: tope duro de intentos, como red de seguridad.
Future<T> retryOnNetworkError<T>(
  Future<T> Function() action, {
  int attempts = 8,
  Duration initialDelay = const Duration(milliseconds: 300),
  Duration maxDelay = startupRetryMaxDelay,
  Duration maxElapsed = startupRetryBudget,
  bool Function()? shouldRetry,
}) async {
  final stopwatch = Stopwatch()..start();
  var delay = initialDelay;
  for (var attempt = 1; ; attempt++) {
    try {
      return await action();
    } catch (e) {
      if (attempt >= attempts) rethrow;
      if (!isTransientNetworkError(e)) rethrow;
      if (shouldRetry != null && !shouldRetry()) rethrow;
      // Si la espera se saliera del presupuesto, no vale la pena dormirla:
      // el usuario ya lleva demasiado mirando un esqueleto de carga.
      if (stopwatch.elapsed + delay > maxElapsed) rethrow;
      await Future<void>.delayed(delay);
      delay = delay * 2 > maxDelay ? maxDelay : delay * 2;
    }
  }
}

/// `true` si [error] parece un fallo de red pasajero (DNS aún sin resolver,
/// socket rechazado, timeout), y no un error de la respuesta en sí.
///
/// Se inspecciona el texto además del tipo porque los errores de red llegan
/// envueltos en `DioException` y perderían el `SocketException` original.
bool isTransientNetworkError(Object error) {
  if (error is SocketException || error is TimeoutException) return true;
  final text = error.toString().toLowerCase();
  return text.contains('failed host lookup') ||
      text.contains('socketexception') ||
      text.contains('connection error') ||
      text.contains('connection refused') ||
      text.contains('connection closed') ||
      text.contains('network is unreachable') ||
      text.contains('timeout');
}
