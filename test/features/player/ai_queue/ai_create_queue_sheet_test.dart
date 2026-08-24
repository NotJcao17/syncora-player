import 'dart:async';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/apis/deezer_provider.dart';
import 'package:syncora_player/data/local_db/database_provider.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/models/deezer/deezer_search_result.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/data/services/ai_assistant_service.dart';
import 'package:syncora_player/data/services/ai_key_storage.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/player_providers.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';
import 'package:syncora_player/features/player/widgets/queue_view.dart';

/// Fakes mínimos del motor de audio / extracción -- mismo patrón que
/// `test/features/player/mini_player_test.dart` y
/// `test/features/player/syncora_player_controller_test.dart`, con su propia
/// copia (cada test file del proyecto trae la suya en vez de compartir un
/// fixture entre archivos de test).
class _FakeAudioEngine implements AudioEngine {
  final _stateController = StreamController<AudioEngineState>.broadcast();
  final _completionController = StreamController<void>.broadcast();
  final _logStreamController = StreamController<String>.broadcast();

  AudioEngineState _state = AudioEngineState.initial;

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;
  @override
  Stream<void> get completionStream => _completionController.stream;
  @override
  Stream<String> get logStream => _logStreamController.stream;
  @override
  Duration get position => _state.position;
  @override
  Duration get duration => _state.duration;

  void _emit(AudioEngineState newState) {
    _state = newState;
    _stateController.add(_state);
  }

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers}) async {
    _emit(_state.copyWith(processingState: AudioProcessingState.ready, duration: const Duration(seconds: 180)));
  }

  @override
  Future<void> setLocalSource(String path) async {
    _emit(_state.copyWith(processingState: AudioProcessingState.ready, duration: const Duration(seconds: 180)));
  }

  @override
  Future<void> play() async => _emit(_state.copyWith(playing: true));
  @override
  Future<void> pause() async => _emit(_state.copyWith(playing: false));
  @override
  Future<void> stop() async =>
      _emit(_state.copyWith(playing: false, processingState: AudioProcessingState.idle));
  @override
  Future<void> microFadeOut() async {}
  @override
  Future<void> seek(Duration position) async => _emit(_state.copyWith(position: position));
  @override
  Future<void> setSpeed(double speed) async => _emit(_state.copyWith(speed: speed));
  @override
  Future<void> setVolume(double volume) async => _emit(_state.copyWith(volume: volume));
  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {}

  @override
  Future<void> crossfadeToLocalSource(String path, Duration duration) async {
    await stop();
    await setLocalSource(path);
    await play();
  }

  @override
  Future<void> dispose() async {
    await _stateController.close();
    await _completionController.close();
    await _logStreamController.close();
  }
}

class _FakeExtractionService implements ExtractionService {
  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    String? trackTitle,
    String? trackArtist,
    int? durationSeconds,
    ExtractionPriority priority = ExtractionPriority.streaming,
  }) async {
    return const ExtractionSuccess(requestId: 'req_1', streamUrl: 'https://example.com/stream.mp3', headers: {});
  }

  @override
  void dispose() {}
  @override
  void resetEngine() {}
  @override
  Stream<String> get onLogMessage => const Stream.empty();
}

/// Mismo motivo que en `ai_create_playlist_sheet_test.dart` (7.F.1): sin este
/// doble, `AiAssistantService.invoke` llama al `FlutterSecureStorage` real
/// (canal de plataforma sin binding en `flutter_test`) antes incluso de
/// intentar contactar la Edge Function, y se cuelga.
class _FakeAiKeyStorage implements AiKeyStorage {
  @override
  Future<String?> getKey() async => null;
  @override
  Future<void> setKey(String key) async {}
  @override
  Future<void> deleteKey() async {}
}

/// Doble de [DeezerApi] para el camino feliz: siempre devuelve la misma
/// pista, sin tocar la red real.
class _FakeDeezerApi extends DeezerApi {
  final DeezerTrack track;
  _FakeDeezerApi(this.track);

  @override
  Future<DeezerSearchResult> search(String query, {DeezerSearchType type = DeezerSearchType.all}) async {
    return DeezerSearchResult(tracks: [track]);
  }
}

/// Construye un [AiAssistantService] cuyo `invoke` devuelve directamente
/// [result], sin pasar por `Supabase.instance` ni por la red. [onInvoke]
/// permite capturar el body enviado (para verificar `interleave`/
/// `contextTracks`/`count`).
AiAssistantService _fakeQueueAiService(
  Map<String, dynamic> result, {
  void Function(Map<String, dynamic> body)? onInvoke,
}) {
  return AiAssistantService(
    keyStorage: _FakeAiKeyStorage(),
    invoke: (functionName, {headers = const {}, body}) async {
      if (body is Map) onInvoke?.call(Map<String, dynamic>.from(body));
      return FunctionResponse(status: 200, data: {'action': 'create_queue', 'result': result});
    },
  );
}

/// Fase 7.F.2 -- pruebas de widget de "Crear cola con IA": el botón/atajo en
/// `queue_view.dart` y el flujo completo (formulario -> generación ->
/// matching -> vista previa -> aplicar a la cola).
void main() {
  final fakeTrack = DeezerTrack(
    id: 1,
    title: 'Song A',
    artistName: 'Artist A',
    artistId: 10,
    albumTitle: 'Album A',
    albumId: 100,
    coverUrl: 'https://cover.example/1.jpg',
    durationSec: 200,
  );

  late SyncoraDatabase db;

  setUp(() {
    // `TrackTile` (usado por `QueueView` para "reproduciendo ahora" y cada
    // fila de las colas) consulta el estado de descarga vía
    // `downloadedTrackDaoProvider` -> `syncoraDatabaseProvider`. Sin
    // sobreescribir ese provider con una base en memoria,
    // `SyncoraDatabase()` abre el archivo real de la plataforma y deja
    // temporizadores de limpieza de streams de Drift pendientes al cerrar el
    // test (mismo gotcha documentado en `ai_create_playlist_sheet_test.dart`
    // -- `closeStreamsSynchronously` es el flag oficial de Drift para esto).
    db = SyncoraDatabase(
      DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
    );
  });

  tearDown(() async {
    await db.close();
  });

  // El formulario completo (prompt + 2 toggles + dropdown + botones) no
  // entra en el viewport por defecto de `flutter_test` (800x600): al ser un
  // `ListView` (aunque `shrinkWrap: true`), Flutter solo construye los
  // elementos dentro del viewport visible (lazy sliver), así que la fila de
  // botones al final ("Cancelar"/"Crear cola con IA") ni siquiera llega a
  // construirse sin esto -- mismo ajuste que ya usa `mini_player_test.dart`
  // para casos similares.
  void growViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  SyncoraPlayerController buildController() {
    final controller = SyncoraPlayerController(engine: _FakeAudioEngine(), extractionService: _FakeExtractionService());
    controller.init();
    return controller;
  }

  Widget buildHarness(
    SyncoraPlayerController controller, {
    AiAssistantService? aiService,
    DeezerApi? deezerApi,
  }) {
    return ProviderScope(
      overrides: [
        syncoraDatabaseProvider.overrideWithValue(db),
        syncoraPlayerControllerProvider.overrideWith((ref) => controller),
        aiKeyStorageProvider.overrideWithValue(_FakeAiKeyStorage()),
        if (aiService != null) aiAssistantServiceProvider.overrideWithValue(aiService),
        if (deezerApi != null) deezerApiProvider.overrideWithValue(deezerApi),
      ],
      child: const MaterialApp(
        home: Scaffold(body: QueueView()),
      ),
    );
  }

  testWidgets('con la cola vacía, el empty state ofrece "Crear cola con IA" como acción (D-15)', (tester) async {
    final controller = buildController();
    await tester.pumpWidget(buildHarness(controller));
    await tester.pumpAndSettle();

    expect(find.text('La cola está vacía'), findsOneWidget);
    expect(find.text('Crear cola con IA'), findsOneWidget);
  });

  testWidgets('con la cola no vacía, el toolbar muestra el atajo "Mejorar esta cola"',
      (tester) async {
    final controller = buildController();
    await controller.setQueue(
      const [SyncoraTrack(id: 't1', title: 'T1', artist: 'A1')],
      autoplay: false,
    );
    await tester.pumpWidget(buildHarness(controller));
    await tester.pumpAndSettle();

    // El `IconButton` suelto que abría el mismo sheet sin `autoImprove` se
    // quitó (pruebas manuales: dos botones de IA pegados se veían
    // redundantes) -- "Mejorar esta cola" queda como único punto de entrada
    // visible en el toolbar; el panel completo sigue accesible desde el
    // `EmptyStateWidget` cuando la cola está vacía.
    expect(find.byTooltip('Crear cola con IA'), findsNothing);
    expect(find.text('Mejorar esta cola'), findsOneWidget);
  });

  testWidgets('cola nueva sin prompt exige texto o "basada en cola actual" (validación local, sin llamar a la IA)',
      (tester) async {
    growViewport(tester);
    final controller = buildController();
    await tester.pumpWidget(buildHarness(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Crear cola con IA')); // botón de acción del empty state
    await tester.pumpAndSettle();

    // El título de la hoja y el botón de submit comparten el mismo texto
    // ("Crear cola con IA") -- el botón de submit es un `ElevatedButton.icon`,
    // cuyo tipo en runtime es una subclase privada de `ElevatedButton`
    // (`find.byType`/`widgetWithText` hacen match exacto de tipo, no por
    // subtipo, así que `widgetWithText(ElevatedButton, ...)` nunca lo
    // encuentra) -- se ubica por texto y se toma el último de los dos
    // matches (el título siempre precede al botón en el árbol).
    await tester.tap(find.text('Crear cola con IA').last);
    await tester.pumpAndSettle();

    expect(find.text('Escribe una descripción o elige "Basada en la cola actual".'), findsOneWidget);
  });

  testWidgets('camino feliz "cola nueva" + "cola manual": genera, matchea, y agrega al final de la manual (D-2)',
      (tester) async {
    growViewport(tester);
    final controller = buildController();
    Map<String, dynamic>? sentBody;

    await tester.pumpWidget(buildHarness(
      controller,
      aiService: _fakeQueueAiService(
        {
          'tracks': [
            {'title': 'Song A', 'artist': 'Artist A'},
          ],
        },
        onInvoke: (b) => sentBody = b,
      ),
      deezerApi: _FakeDeezerApi(fakeTrack),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Crear cola con IA'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'algo movido para entrenar');
    await tester.tap(find.text('Cola manual'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Crear cola con IA').last);
    await tester.pumpAndSettle();

    // Llegó a la vista previa con la pista matcheada, y mandó el modo
    // correcto a la Edge Function (D-1: sin contexto en modo "cola nueva").
    expect(find.text('Agregar a la cola'), findsOneWidget);
    expect(find.text('Song A'), findsOneWidget);
    expect(sentBody?['interleave'], false);
    expect(sentBody?['contextTracks'], isNull);

    await tester.tap(find.text('Agregar a la cola'));
    // `AppToast` de éxito con auto-dismiss a los 3s (mismo patrón que
    // 7.F.1) -- un pumpAndSettle con duración corta puede asentarse antes de
    // que ese timer dispare y dejarlo pendiente al cerrar el test.
    await tester.pumpAndSettle(const Duration(seconds: 4));

    // No había nada sonando (nunca se llamó `setQueue` en este test): la
    // única pista agregada se promueve de inmediato a `currentTrack`, igual
    // que `addToQueue` (P0.3) -- por eso no queda en `manualQueue`, que es
    // el comportamiento correcto y ya cubierto a nivel de controlador en
    // `syncora_player_controller_test.dart`.
    expect(controller.state.currentTrack?.id, '1');
    expect(controller.state.manualQueue, isEmpty);
  });

  testWidgets('atajo "Mejorar esta cola" (D-9): dispara directo sin mostrar el formulario, e intercala en la automática',
      (tester) async {
    final controller = buildController();
    await controller.setQueue(
      [
        const SyncoraTrack(id: 'seed1', title: 'Seed 1', artist: 'Seed Artist'),
        const SyncoraTrack(id: 'seed2', title: 'Seed 2', artist: 'Seed Artist'),
      ],
      autoplay: false,
    );
    Map<String, dynamic>? sentBody;

    await tester.pumpWidget(buildHarness(
      controller,
      aiService: _fakeQueueAiService(
        {
          'tracks': [
            {'title': 'Song A', 'artist': 'Artist A'},
          ],
        },
        onInvoke: (b) => sentBody = b,
      ),
      deezerApi: _FakeDeezerApi(fakeTrack),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mejorar esta cola'));
    // Primer frame tras abrir la hoja: ya debe estar en "generando", sin
    // haber mostrado el formulario ni un frame de por medio (D-9: "dispara
    // directo, sin abrir el panel completo").
    await tester.pump();
    expect(find.text('Origen'), findsNothing);
    expect(find.text('Generando canciones para tu cola con IA...'), findsOneWidget);

    await tester.pumpAndSettle();

    // D-9: basada en la cola actual + intercalar + 25 -- se verifica que
    // efectivamente viajó así a la Edge Function.
    expect(sentBody?['interleave'], true);
    expect(sentBody?['count'], isNotNull);
    final contextTracks = sentBody?['contextTracks'] as List?;
    expect(contextTracks, isNotNull);
    expect(contextTracks!.isNotEmpty, isTrue);

    expect(find.text('Intercalar en la cola'), findsOneWidget);
    await tester.tap(find.text('Intercalar en la cola'));
    await tester.pumpAndSettle(const Duration(seconds: 4));

    expect(controller.state.autoQueue.any((t) => t.id == '1'), isTrue,
        reason: 'la pista sugerida por la IA (matcheada a id Deezer 1) debe haber quedado en la automática');
    expect(controller.state.manualQueue, isEmpty, reason: 'D-1: intercalar nunca toca la cola manual');
  });
}
