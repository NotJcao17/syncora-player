import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/images/custom_image_service.dart';
import '../../../core/settings/app_settings_store.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/sync/sync_service.dart';
import '../../home/home_providers.dart';
import '../../home/mixes/mix_providers.dart';
import '../../home/mixes/on_repeat_service.dart';
import '../../player/player_providers.dart';
import '../../player/session/player_session_storage.dart';
import '../../search/search_history_storage.dart';
import '../local_mode_provider.dart';
import 'local_library_wipe.dart';
import 'local_mode_storage.dart';
import 'remote_account_check.dart';

/// De quién son los datos locales: el id de la cuenta, o [localModeDataOwner]
/// en modo sin cuenta. Vive en `shared_preferences` (`AppSettingsStore`).
///
/// Bug real (2026-10-05): cerrar sesión solo cerraba la sesión de Supabase.
/// El historial, "On Repeat" (que es solo local y el sync nunca poda), la
/// cola del reproductor y las búsquedas recientes se quedaban en el
/// dispositivo, así que la siguiente cuenta veía Inicio, On Repeat y la
/// canción en curso de la anterior. Ahora:
///
/// - **Cerrar sesión** borra esos datos ([AccountDataGuard.signOut]) pero
///   deja anotado el dueño, para que una escritura tardía de la cuenta que se
///   fue (un sync que ya estaba en vuelo) también se limpie si entra otra.
/// - **Entrar con otra cuenta**, o pasar al modo sin cuenta, borra lo local
///   antes de mostrar nada si el dueño anotado es otro.
/// - **Volver a entrar con la misma cuenta** no borra nada: la app sigue
///   sirviendo sin conexión.
///
/// Las descargas no se tocan nunca: son del dispositivo, no de una cuenta
/// (misma regla que `wipeLocalLibrary`).
const String localDataOwnerKey = 'account.local_data_owner';

/// Dueño de los datos en modo sin cuenta.
const String localModeDataOwner = 'local';

/// ¿Hay que borrar lo local antes de que [newOwner] lo vea?
///
/// Sin dueño anotado (instalaciones anteriores a este cambio, o la primera
/// vez) no se borra: no hay forma de saber de quién son, y borrar a ciegas le
/// quitaría al usuario de siempre su biblioteca sin conexión.
bool shouldWipeLocalData({required String? storedOwner, required String newOwner}) =>
    storedOwner != null && storedOwner != newOwner;

/// Tras un cierre de sesión que hizo Supabase solo: ¿se borran los datos
/// locales? Solo si el servidor dijo **explícitamente** que la cuenta dueña
/// ya no existe ([accountExists] `false`; `null` es "no se pudo saber") y
/// nadie entró ni cambió el dueño mientras se preguntaba (en ese caso ya se
/// encargó `claimFor`).
bool shouldWipeAfterServerSignOut({
  required bool? accountExists,
  required bool signedInAgain,
  required bool ownerChanged,
}) =>
    accountExists == false && !signedInAgain && !ownerChanged;

final _uuidPattern = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Borra lo que pertenece a una cuenta y no necesita el reproductor vivo:
/// biblioteca, carpetas, historial, imágenes propias, foto del modo local y
/// búsquedas recientes. Se usa también al arrancar, antes de `runApp`.
///
/// [clearPlayerSession] solo cuando el controlador del reproductor todavía no
/// existe; si existe, su reinicio ya deja la sesión vacía.
Future<void> wipeAccountDataAtRest({
  required SyncoraDatabase db,
  required CustomImageService images,
  required LocalModeStorage localModeStorage,
  required SearchHistoryStorage searchHistory,
  Future<void> Function()? clearPlayerSession,
}) async {
  await wipeLocalLibrary(
    dao: db.playlistDao,
    savedAlbumDao: db.savedAlbumDao,
    historyDao: db.listeningHistoryDao,
    folderDao: db.folderDao,
  );
  await images.deleteAllLocal();
  try {
    await localModeStorage.setAvatarImagePath(null);
  } catch (_) {}
  await searchHistory.clear();
  await clearPlayerSession?.call();
}

class AccountDataGuard {
  AccountDataGuard(this._ref);

  final Ref _ref;

  /// Tope para subir el historial pendiente al cerrar sesión: sin red no se
  /// puede esperar indefinidamente con el usuario mirando un indicador.
  static const _historyPushTimeout = Duration(seconds: 8);

  AppSettingsStore get _settings => _ref.read(appSettingsStoreProvider);

  String? get owner => _settings.getString(localDataOwnerKey);

  Future<void> setOwner(String owner) => _settings.setString(localDataOwnerKey, owner);

  /// Deja los datos locales listos para [newOwner]: los borra si eran de otro
  /// y lo anota como dueño. Devuelve si hubo borrado.
  Future<bool> claimFor(String newOwner) async {
    final wipe = shouldWipeLocalData(storedOwner: owner, newOwner: newOwner);
    if (wipe) await wipeNow();
    await setOwner(newOwner);
    return wipe;
  }

  /// Cierra sesión y borra los datos de la cuenta del dispositivo.
  ///
  /// Antes de cerrar la sesión se para el reproductor (cierra la escucha en
  /// curso) y se sube el historial pendiente: después ya no hay JWT con el que
  /// subirlo y el borrado se lo llevaría.
  Future<void> signOut() async {
    await _resetPlayerIfAlive();
    try {
      await _ref.read(syncServiceProvider).syncListeningHistory().timeout(_historyPushTimeout);
    } catch (_) {}
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
    await wipeNow(playerAlreadyReset: true);
  }

  /// `true` mientras este dispositivo elimina su propia cuenta
  /// (`delete_account_flow.dart`): entre la RPC y el cierre de sesión, un sync
  /// vería `user_not_found` y no debe avisar "desde otro dispositivo".
  bool deletingAccountHere = false;

  Future<void>? _remoteGone;

  /// La cuenta se eliminó en otro dispositivo (el servidor respondió
  /// `user_not_found`, ver `remote_account_check.dart`): lo mismo que al
  /// eliminarla aquí, sin la RPC. Cierra sesión y borra lo local (las
  /// descargas se quedan). El dueño anotado sigue siendo la cuenta borrada,
  /// así que si algo se escapa del borrado se limpia cuando entre otra.
  ///
  /// [userId] es la cuenta que el servidor dijo que no existe: si para
  /// entonces la sesión es de otra, no se toca nada.
  Future<void> handleAccountDeletedElsewhere(String userId) =>
      _onRemoteSessionGone(userId, wipe: true, notice: accountDeletedElsewhereNotice);

  /// La sesión se cerró en el servidor (`session_not_found`), pero la cuenta
  /// existe: solo se cierra la sesión. Los datos se quedan con su dueño, como
  /// cuando Supabase cierra una sesión vencida: si vuelve la misma cuenta,
  /// siguen ahí; si entra otra, se borran.
  Future<void> handleSessionRevoked(String userId) =>
      _onRemoteSessionGone(userId, wipe: false, notice: sessionClosedNotice);

  Future<void> _onRemoteSessionGone(String userId, {required bool wipe, required String notice}) {
    final inFlight = _remoteGone;
    if (inFlight != null) return inFlight;
    final future = _closeSessionFor(userId, wipe: wipe, notice: notice);
    _remoteGone = future;
    future.whenComplete(() {
      _remoteGone = null;
    });
    return future;
  }

  Future<void> _closeSessionFor(String userId, {required bool wipe, required String notice}) async {
    if (deletingAccountHere) return;
    final auth = Supabase.instance.client.auth;
    if (auth.currentUser?.id != userId) return;
    // El aviso antes del cierre de sesión: la pantalla de inicio lo lee al
    // montarse, y se monta en cuanto la sesión desaparece.
    setPendingAuthNotice(notice);
    if (wipe) await _resetPlayerIfAlive();
    try {
      // Alcance local: el servidor ya no tiene sesión que cerrar.
      await auth.signOut();
    } catch (_) {}
    if (wipe) await wipeNow(playerAlreadyReset: true);
  }

  Future<void>? _serverSignOut;

  /// Supabase cerró la sesión solo: la renovación del token se rechazó (ver
  /// `serverSignOutWatcherProvider`). Pasa con una cuenta eliminada desde
  /// otro dispositivo si este no usó la app en la última hora, porque con la
  /// app cerrada o en segundo plano no renueva el token, y ya no queda
  /// ninguno con el que preguntar a `/user`. Se pregunta a la RPC
  /// `account_exists` (sin sesión) por el dueño de los datos locales.
  Future<void> handleSessionEndedByServer() {
    final inFlight = _serverSignOut;
    if (inFlight != null) return inFlight;
    final future = _afterServerSignOut();
    _serverSignOut = future;
    future.whenComplete(() {
      _serverSignOut = null;
    });
    return future;
  }

  Future<void> _afterServerSignOut() async {
    final accountId = owner;
    if (deletingAccountHere || accountId == null || !_uuidPattern.hasMatch(accountId)) {
      setPendingAuthNotice(sessionClosedNotice, keepExisting: true);
      return;
    }
    final exists = await _accountExists(accountId);
    final wipe = shouldWipeAfterServerSignOut(
      accountExists: exists,
      signedInAgain: Supabase.instance.client.auth.currentUser != null,
      ownerChanged: owner != accountId,
    );
    if (!wipe) {
      setPendingAuthNotice(sessionClosedNotice, keepExisting: true);
      return;
    }
    setPendingAuthNotice(accountDeletedElsewhereNotice);
    await _resetPlayerIfAlive();
    await wipeNow(playerAlreadyReset: true);
  }

  /// `true`/`false` según el servidor; `null` si no se pudo saber (sin red,
  /// migración sin aplicar, respuesta inesperada): entonces no se borra nada.
  Future<bool?> _accountExists(String accountId) async {
    try {
      final result = await Supabase.instance.client
          .rpc('account_exists', params: {'account_id': accountId})
          .timeout(const Duration(seconds: 10));
      return result is bool ? result : null;
    } catch (_) {
      return null;
    }
  }

  /// Borrado completo, con el reproductor vivo y la UI montada.
  Future<void> wipeNow({bool playerAlreadyReset = false}) async {
    final playerAlive = _ref.exists(syncoraPlayerControllerProvider);
    if (!playerAlreadyReset) await _resetPlayerIfAlive();

    try {
      await wipeAccountDataAtRest(
        db: _ref.read(syncoraDatabaseProvider),
        images: _ref.read(customImageServiceProvider),
        localModeStorage: _ref.read(localModeStorageProvider),
        searchHistory: _ref.read(searchHistoryStorageProvider),
        clearPlayerSession: playerAlive ? null : () => PlayerSessionStorage().clear(),
      );
    } catch (_) {
      // Best-effort: lo que no se pudo borrar se vuelve a intentar la próxima
      // vez que entre otra cuenta, porque el dueño anotado sigue siendo el
      // anterior.
    }

    // Los providers que ya calcularon algo a partir del historial o de la
    // biblioteca lo guardan en memoria hasta que alguien los invalide.
    _ref.invalidate(searchHistoryProvider);
    _ref.invalidate(localAvatarImageProvider);
    _ref.invalidate(recentlyPlayedProvider);
    _ref.invalidate(mixesProvider);
    _ref.invalidate(onRepeatPlaylistProvider);
    _ref.invalidate(newReleasesFromArtistsProvider);
    _ref.invalidate(relatedArtistsProvider);
  }

  Future<void> _resetPlayerIfAlive() async {
    if (!_ref.exists(syncoraPlayerControllerProvider)) return;
    try {
      await _ref.read(syncoraPlayerControllerProvider).resetForAccountChange();
    } catch (_) {}
  }
}

final accountDataGuardProvider = Provider<AccountDataGuard>((ref) => AccountDataGuard(ref));
