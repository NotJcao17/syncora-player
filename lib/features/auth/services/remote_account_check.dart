import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'account_data_owner.dart';

/// ¿Sigue existiendo en el servidor la cuenta con la que hay sesión? (ronda 7)
///
/// **El caso:** se elimina la cuenta en el PC y el celular sigue con sesión.
/// Su token de acceso sigue valiendo hasta que vence (1 h por defecto), porque
/// la API solo comprueba la firma. Mientras tanto la nube le respondía "no
/// tienes nada", el sync vaciaba su biblioteca sin decir nada y cada escritura
/// fallaba. Al vencer el token, la renovación fallaba y Supabase cerraba la
/// sesión sin explicación.
///
/// **La señal, y solo esa:** `GET /auth/v1/user` responde **403 con
/// `error_code: user_not_found`** cuando el usuario del token no existe
/// (código del servidor de Auth, `maybeLoadUserOrSession`: busca el usuario
/// antes que la sesión). Una sesión cerrada desde otro lado da
/// `session_not_found`. **Cualquier otra cosa** (sin red, 5xx, token vencido,
/// un error sin código) es "no se sabe" y no hace nada: nunca se borra lo
/// local por una duda.
enum RemoteAccountStatus { exists, deleted, sessionRevoked, unknown }

/// Clasifica el error de `auth.getUser()`. Pública para tests.
RemoteAccountStatus classifyAccountCheckError(Object error) {
  if (error is AuthApiException && error.statusCode == '403') {
    if (error.code == 'user_not_found') return RemoteAccountStatus.deleted;
    if (error.code == 'session_not_found') return RemoteAccountStatus.sessionRevoked;
  }
  return RemoteAccountStatus.unknown;
}

typedef RemoteAccountCheck = ({RemoteAccountStatus status, String? userId});

class RemoteAccountChecker {
  RemoteAccountChecker({
    required this.currentUserId,
    required this.fetchUser,
    required this.sessionExpired,
    required this.refreshSession,
    DateTime Function()? now,
    this.okTtl = const Duration(minutes: 5),
  }) : _now = now ?? DateTime.now;

  final String? Function() currentUserId;

  /// `auth.getUser()`: lanza el error del servidor si no responde 200.
  final Future<void> Function() fetchUser;
  final bool Function() sessionExpired;
  final Future<void> Function() refreshSession;
  final DateTime Function() _now;

  /// Tras confirmar que la cuenta existe no se vuelve a preguntar en este
  /// tiempo (lo mismo que dura la caché del sync): como mucho una petición de
  /// Auth cada 5 minutos.
  final Duration okTtl;

  String? _okUserId;
  DateTime? _okAt;
  Future<RemoteAccountCheck>? _inFlight;
  String? _inFlightUserId;

  Future<RemoteAccountCheck> check({bool force = false}) {
    final userId = currentUserId();
    if (userId == null) return Future.value((status: RemoteAccountStatus.unknown, userId: null));
    final okAt = _okAt;
    if (!force && _okUserId == userId && okAt != null && _now().difference(okAt) < okTtl) {
      return Future.value((status: RemoteAccountStatus.exists, userId: userId));
    }
    // Solo se comparte una comprobación de la misma cuenta: la de una cuenta
    // anterior (p. ej. la eliminada) no debe decidir el primer sync de otra.
    final inFlight = _inFlight;
    if (inFlight != null && _inFlightUserId == userId) return inFlight;
    final future = _run(userId);
    _inFlight = future;
    _inFlightUserId = userId;
    // Cuerpo de bloque a propósito: un `whenComplete` de flecha que devuelve
    // el propio futuro se espera a sí mismo (`docs/fases/inicio_y_explorar.md`).
    future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
        _inFlightUserId = null;
      }
    });
    return future;
  }

  Future<RemoteAccountCheck> _run(String userId) async {
    // Con el token vencido, `/user` diría 401 y no sabríamos nada. Se renueva
    // primero; si la renovación se rechaza, Supabase cierra la sesión solo.
    try {
      if (sessionExpired()) await refreshSession();
    } catch (_) {
      return (status: RemoteAccountStatus.unknown, userId: userId);
    }
    try {
      await fetchUser();
      _okUserId = userId;
      _okAt = _now();
      return (status: RemoteAccountStatus.exists, userId: userId);
    } catch (e) {
      return (status: classifyAccountCheckError(e), userId: userId);
    }
  }
}

final remoteAccountCheckerProvider = Provider<RemoteAccountChecker>((ref) {
  final auth = Supabase.instance.client.auth;
  return RemoteAccountChecker(
    currentUserId: () => auth.currentUser?.id,
    fetchUser: () => auth.getUser(),
    sessionExpired: () => auth.currentSession?.isExpired ?? false,
    refreshSession: () => auth.refreshSession(),
  );
});

/// Lo que el sync consulta antes de tocar nada: `false` si la cuenta ya no
/// existe o su sesión se cerró en el servidor (y en ese caso arranca el
/// cierre de sesión). `true` también cuando no se puede saber: sin red el
/// sync falla igual, como siempre. `null` en tests (sin Supabase).
final accountGateProvider = Provider<Future<bool> Function()?>((ref) {
  if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return null;
  return () async {
    final RemoteAccountCheck result;
    try {
      result = await ref.read(remoteAccountCheckerProvider).check();
    } catch (_) {
      return true;
    }
    // La sesión tiene que seguir siendo la de la cuenta comprobada. Si
    // desapareció mientras tanto (la renovación del token se rechazó, que
    // es justo lo que pasa con una cuenta eliminada y el token vencido) o
    // cambió de cuenta, los repositorios devuelven listas vacías sin sesión
    // y el sync podaría la biblioteca local: no se sincroniza.
    final userId = result.userId;
    if (userId == null || Supabase.instance.client.auth.currentUser?.id != userId) return false;
    switch (result.status) {
      case RemoteAccountStatus.deleted:
        unawaited(ref.read(accountDataGuardProvider).handleAccountDeletedElsewhere(userId));
        return false;
      case RemoteAccountStatus.sessionRevoked:
        unawaited(ref.read(accountDataGuardProvider).handleSessionRevoked(userId));
        return false;
      case RemoteAccountStatus.exists:
      case RemoteAccountStatus.unknown:
        return true;
    }
  };
});

/// Aviso para la pantalla de inicio de sesión cuando la sesión se cerró sin
/// que el usuario lo pidiera. Se lee y se limpia al mostrarlo
/// ([takePendingAuthNotice]).
final ValueNotifier<String?> pendingAuthNotice = ValueNotifier<String?>(null);
DateTime? _pendingAuthNoticeAt;

/// Más viejo que esto ya no explica nada de lo que el usuario está haciendo
/// (p. ej. el cierre por sesión vencida al arrancar, si después siguió en
/// modo local y abre el inicio de sesión días más tarde).
const Duration _authNoticeMaxAge = Duration(minutes: 10);

void setPendingAuthNotice(String notice, {bool keepExisting = false}) {
  if (keepExisting && pendingAuthNotice.value != null) return;
  _pendingAuthNoticeAt = DateTime.now();
  pendingAuthNotice.value = notice;
}

/// El aviso pendiente si es reciente, y lo limpia.
String? takePendingAuthNotice() {
  final notice = pendingAuthNotice.value;
  final at = _pendingAuthNoticeAt;
  _pendingAuthNoticeAt = null;
  if (notice != null) pendingAuthNotice.value = null;
  if (notice == null || at == null || DateTime.now().difference(at) > _authNoticeMaxAge) return null;
  return notice;
}

const String accountDeletedElsewhereNotice = 'Tu cuenta se eliminó desde otro dispositivo. '
    'Se borraron sus datos de este dispositivo (las descargas se conservan).';
const String sessionClosedNotice = 'Tu sesión se cerró. Vuelve a iniciar sesión.';

