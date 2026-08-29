import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/extraction/extraction_provider.dart';
import '../../core/utils/connectivity_service.dart';
import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/local_db/daos/playlist_dao.dart';
import '../../data/sync/sync_service.dart';
import '../auth/local_mode_provider.dart';
import 'audio_engine/audio_engine_factory.dart';
import 'os_controls/syncora_audio_handler.dart';
import 'os_controls/windows_media_controls.dart';
import 'player_models.dart';
import 'radio/radio_service.dart';
import 'syncora_player_controller.dart';

/// Toggle de Configuración para radio/cola infinita (Fase 7.B, D-10):
/// activada por defecto. Como el proyecto todavía no tiene
/// `shared_preferences`, no persiste entre reinicios — mismo comportamiento
/// (no una regresión) que `downloadWifiOnlyProvider`
/// (`lib/features/download/download_provider.dart`).
final radioEnabledProvider = StateProvider<bool>((ref) => true);

/// Duración del crossfade (Fase 7.D.5, off / 2s / 4s / 6s en Configuración).
/// `Duration.zero` == "off" (default, conservador). Mismo patrón
/// no-persistido que `radioEnabledProvider`/`downloadWifiOnlyProvider` — el
/// proyecto todavía no tiene `shared_preferences`.
final crossfadeDurationProvider = StateProvider<Duration>((ref) => Duration.zero);

AudioHandler? _globalAndroidAudioHandler;

bool get _isTestEnv {
  try {
    final name = WidgetsBinding.instance.runtimeType.toString();
    return name.contains('Test') || name.contains('Automated');
  } catch (_) {
    return true;
  }
}

/// Provider principal del controlador de reproducción.
///
/// Gestiona la única fuente de la verdad del reproductor ([SyncoraPlayerController])
/// y acopla los adaptadores del sistema operativo (`audio_service` en Android,
/// `smtc_windows` en Windows).
final syncoraPlayerControllerProvider =
    ChangeNotifierProvider<SyncoraPlayerController>((ref) {
  final engine = createAudioEngine(
    fadeDurationGetter: () => ref.read(crossfadeDurationProvider),
  );
  final extractionService = ref.watch(extractionServiceProvider);
  final deezerApi = ref.watch(deezerApiProvider);
  final downloadedTrackDao = ref.watch(downloadedTrackDaoProvider);
  final listeningHistoryDao = ref.watch(listeningHistoryDaoProvider);
  final playlistDao = ref.watch(playlistDaoProvider);
  final radioService = RadioService(deezerApi: deezerApi);

  final controller = SyncoraPlayerController(
    engine: engine,
    extractionService: extractionService,
    deezerApi: deezerApi,
    downloadedTrackDao: downloadedTrackDao,
    listeningHistoryDao: listeningHistoryDao,
    radioService: radioService,
    isConnectedGetter: () => ref.read(isConnectedProvider).value ?? true,
    radioEnabledGetter: () => ref.read(radioEnabledProvider),
    crossfadeDurationGetter: () => ref.read(crossfadeDurationProvider),
    onListenRecorded: () {
      // Sube la escucha apenas se graba: antes solo se subía en
      // `syncOnStartup()` o al refrescar Estadísticas, por eso lo escuchado en
      // el celular no aparecía en el PC hasta abrir Estadísticas en el celular.
      // En modo local no hay nada que subir.
      if (ref.read(localModeProvider)) return;
      ref.read(syncServiceProvider).pushListeningHistoryIfDue();
    },
  );

  controller.init();

  if (!kIsWeb && Platform.isWindows && !_isTestEnv) {
    try {
      final winControls = WindowsMediaControls(controller, playlistDao);
      ref.onDispose(winControls.dispose);
    } catch (e) {
      debugPrint('WindowsMediaControls no disponible en este entorno: $e');
    }
  } else if (!kIsWeb && Platform.isAndroid) {
    try {
      _initAndroidAudioService(controller, playlistDao);
    } catch (e) {
      debugPrint('AndroidAudioService no disponible en este entorno: $e');
    }
  }

  return controller;
});

void _initAndroidAudioService(SyncoraPlayerController controller, [PlaylistDao? playlistDao]) {
  final currentHandler = _globalAndroidAudioHandler;
  if (currentHandler != null) {
    if (currentHandler is SyncoraAudioHandler) {
      currentHandler.updateController(controller, playlistDao: playlistDao);
    }
    return;
  }
  AudioService.init(
    builder: () => SyncoraAudioHandler(controller, playlistDao: playlistDao),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.syncora.player',
      androidNotificationChannelName: 'Syncora Player',
      androidNotificationOngoing: true,
      // Android exige que el icono chico de la notificacion sea monocromo
      // (solo alfa): con `mipmap/ic_launcher`, que es a color, el sistema lo
      // dibujaba como un cuadro blanco o directamente lo omitia. El proyecto ya
      // tiene la variante monocroma del logo generada para el launcher.
      androidNotificationIcon: 'drawable/ic_launcher_monochrome',
    ),
  ).then((handler) {
    _globalAndroidAudioHandler = handler;
  });
}

/// Selector reactivo: ¿se está reproduciendo audio?
final isPlayingProvider = Provider<bool>((ref) =>
    ref.watch(syncoraPlayerControllerProvider).state.engine.playing);

/// Selector reactivo: pista actual en reproducción.
final currentTrackProvider = Provider<SyncoraTrack?>((ref) =>
    ref.watch(syncoraPlayerControllerProvider).state.currentTrack);

/// Selector reactivo: snapshot completo del estado del reproductor.
final playerStateProvider = Provider<SyncoraPlayerState>((ref) =>
    ref.watch(syncoraPlayerControllerProvider).state);

/// Selector reactivo: ids de pista marcadas "no disponible esta sesión"
/// (Fase 7.C.2, D-21). Deriva de `SyncoraPlayerState.unavailableTrackIds`,
/// que vive en memoria dentro del controlador — se resetea solo al
/// reiniciar la app (D-21 se cumple gratis, sin persistencia aparte).
final unavailableTrackIdsProvider = Provider<Set<String>>((ref) =>
    ref.watch(playerStateProvider).unavailableTrackIds);

/// StateProvider para controlar la apertura del panel de cola de reproducción en escritorio
final isQueueOpenProvider = StateProvider<bool>((ref) => false);

/// StateProvider para controlar la apertura de la vista central de letras en escritorio
final isLyricsOpenProvider = StateProvider<bool>((ref) => false);

