import 'dart:async';
import 'dart:io';

/// Reintenta [action] cuando falla por un problema de red *transitorio*.
///
/// En el arranque en frío de Android la pila de red todavía no resuelve DNS
/// durante el primer segundo o dos: las primeras peticiones mueren con
/// `SocketException: Failed host lookup` aunque la conexión sea perfecta. Sin
/// reintento, la pantalla de Inicio se quedaba vacía y la sincronización
/// inicial no traía nada hasta que el usuario recargaba a mano.
///
/// Solo reintenta fallos de red. Cualquier otro error se relanza tal cual: un
/// 404 o un error de parseo no mejora por repetirlo, y enmascararlo escondería
/// bugs reales.
Future<T> retryOnNetworkError<T>(
  Future<T> Function() action, {
  int attempts = 3,
  Duration initialDelay = const Duration(milliseconds: 600),
}) async {
  var delay = initialDelay;
  for (var attempt = 1; ; attempt++) {
    try {
      return await action();
    } catch (e) {
      if (attempt >= attempts || !isTransientNetworkError(e)) rethrow;
      await Future<void>.delayed(delay);
      delay *= 2;
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
