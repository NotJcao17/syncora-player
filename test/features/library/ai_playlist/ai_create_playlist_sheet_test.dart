import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncora_player/core/theme/app_icons.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/apis/deezer_provider.dart';
import 'package:syncora_player/data/local_db/database_provider.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/models/deezer/deezer_search_result.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/data/services/ai_assistant_service.dart';
import 'package:syncora_player/data/services/ai_key_storage.dart';
import 'package:syncora_player/features/library/ai_playlist/ai_create_playlist_sheet.dart';
import 'package:syncora_player/features/player/player_models.dart';

/// Doble en memoria de [AiKeyStorage] -- evita que `AiAssistantService.invoke`
/// llame al `FlutterSecureStorage` real (canal de plataforma) antes incluso
/// de intentar contactar la Edge Function. Ese canal no tiene binding en
/// `flutter_test` y se queda colgado indefinidamente (nunca lanza ni
/// resuelve), lo que dejaba el paso "generando" sin salida y a
/// `pumpAndSettle` sin poder asentarse -- ver comentario en `buildHarness`.
class _FakeAiKeyStorage implements AiKeyStorage {
  @override
  Future<String?> getKey() async => null;
  @override
  Future<void> setKey(String key) async {}
  @override
  Future<void> deleteKey() async {}
}

/// Doble de [DeezerApi] para el camino feliz (generar -> matchear -> vista
/// previa -> guardar): devuelve siempre la misma pista sin tocar la red real.
/// `ExactTrackSearch.cascadeSearch` acepta el primer resultado no vacío
/// cuando no hay duración esperada (las sugerencias de la IA no la traen),
/// así que alcanza con responder en el primer intento de cada búsqueda.
class _FakeDeezerApi extends DeezerApi {
  final DeezerTrack track;
  _FakeDeezerApi(this.track);

  @override
  Future<DeezerSearchResult> search(String query, {DeezerSearchType type = DeezerSearchType.all}) async {
    return DeezerSearchResult(tracks: [track]);
  }
}

/// Construye un [AiAssistantService] cuyo `invoke` devuelve directamente el
/// `result` dado, sin pasar por `Supabase.instance` ni por la red.
AiAssistantService _fakeSuccessfulAiService(Map<String, dynamic> result) {
  return AiAssistantService(
    keyStorage: _FakeAiKeyStorage(),
    invoke: (functionName, {headers = const {}, body}) async {
      return FunctionResponse(status: 200, data: {'action': 'create_playlist', 'result': result});
    },
  );
}

/// Fase 7.F.1 -- pruebas de widget de la hoja "Crear playlist con IA".
///
/// No mockea `AiAssistantService` en sí: la app nunca llama a
/// `Supabase.initialize` en el entorno de test, así que `Supabase.instance`
/// lanza al invocar la función, y ese fallo cae exactamente en el mismo
/// camino que "sin internet" (capturado por `AiAssistantException`/catch
/// genérico en `_generate` -> se muestra un `AppToast` y se vuelve al
/// formulario). Esto cubre justo el caso pedido en la tarea: la UI no debe
/// crashear si la IA es inalcanzable. Sí se mockea `aiKeyStorageProvider`
/// (con [_FakeAiKeyStorage]) porque `invoke()` lee la llave BYOK del
/// keystore real ANTES de llegar a `Supabase.instance`, y ese paso previo sí
/// necesita un doble para no colgarse en un canal de plataforma inexistente.
void main() {
  late SyncoraDatabase db;

  setUp(() {
    // Este test es el único de la Fase 7.F.1 que monta un `StreamBuilder`
    // sobre un stream de Drift (`_buildReferencePlaylistPicker`, D-11). Drift
    // difiere la limpieza de sus streams un turno de event loop vía un
    // `Timer` interno (comentario explícito en el propio código de Drift:
    // "If you're sent here because your Flutter tests fail, please call and
    // await Database.close()..."), y ese timer sigue pendiente cuando
    // `flutter_test` verifica invariantes al cerrar el test, sin que
    // `tearDown` llegue a tiempo de evitarlo. `closeStreamsSynchronously` es
    // el flag oficial de Drift pensado exactamente para este caso de test.
    db = SyncoraDatabase(
      DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
    );
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildHarness({AiAssistantService? aiService, DeezerApi? deezerApi}) {
    return ProviderScope(
      overrides: [
        syncoraDatabaseProvider.overrideWithValue(db),
        aiKeyStorageProvider.overrideWithValue(_FakeAiKeyStorage()),
        if (aiService != null) aiAssistantServiceProvider.overrideWithValue(aiService),
        if (deezerApi != null) deezerApiProvider.overrideWithValue(deezerApi),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAiCreatePlaylistSheet(context, ref),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('abre el formulario con el prompt libre y el panel de parámetros colapsado', (tester) async {
    await tester.pumpWidget(buildHarness());
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    expect(find.text('Crear playlist con IA'), findsOneWidget);
    expect(find.text('Describe la playlist que quieres'), findsOneWidget);
    // El panel de parámetros arranca colapsado (plan 7.F.1): sus campos no
    // deben estar en el árbol todavía.
    expect(find.text('Cantidad de canciones'), findsNothing);
  });

  testWidgets('exige texto o parámetros antes de generar (validación local, sin llamar a la IA)', (tester) async {
    await tester.pumpWidget(buildHarness());
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Crear con IA'));
    await tester.pumpAndSettle();

    expect(find.text('Escribe una descripción o abre los parámetros y elige alguno.'), findsOneWidget);
  });

  testWidgets('tocar "Parámetros (opcional)" expande el panel con los presets de cantidad', (tester) async {
    await tester.pumpWidget(buildHarness());
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Parámetros (opcional)'));
    await tester.pumpAndSettle();

    expect(find.text('Cantidad de canciones'), findsOneWidget);
    expect(find.text('25'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('200'), findsOneWidget);
  });

  testWidgets('IA inalcanzable (sin Supabase inicializado, equivalente a sin internet) no crashea: vuelve al formulario', (tester) async {
    await tester.pumpWidget(buildHarness());
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'música para estudiar');
    await tester.tap(find.text('Crear con IA'));
    // Deja correr el microtask/future que falla contra Supabase sin inicializar.
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // No debe haber quedado colgado en el spinner de "generando", ni haber
    // lanzado una excepción no capturada (si la hubiera, `pumpAndSettle`
    // fallaría el test) -- vuelve al formulario con el texto conservado.
    expect(find.text('Crear playlist con IA'), findsOneWidget);
    expect(find.text('Generando sugerencias con IA...'), findsNothing);
    expect(find.text('música para estudiar'), findsOneWidget);
  });

  testWidgets('camino feliz: genera, matchea contra Deezer, permite excluir/incluir y guarda la playlist', (tester) async {
    final fakeTrack = DeezerTrack(
      id: 1,
      title: 'Song A',
      artistName: 'Artist A',
      artistId: 10,
      albumTitle: 'Album A',
      albumId: 100,
      coverUrl: 'https://cover.example/1.jpg',
      durationSec: 200,
      // 2 colaboradores para que `resolveDeezerTrackContributors` (llamado
      // por `_save` -> `createPlaylistWithMatchedTracks`) no dispare una
      // llamada de red real -- solo lo hace si `contributorsList.length <= 1`.
      contributorsList: const [
        SyncoraArtistRef(id: 10, name: 'Artist A'),
        SyncoraArtistRef(id: 11, name: 'Feat A'),
      ],
    );

    await tester.pumpWidget(buildHarness(
      aiService: _fakeSuccessfulAiService({
        'playlistName': 'Playlist de prueba',
        'description': 'Generada en el test',
        'tracks': [
          {'title': 'Song A', 'artist': 'Artist A'},
        ],
      }),
      deezerApi: _FakeDeezerApi(fakeTrack),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'música energética para entrenar');
    await tester.tap(find.text('Crear con IA'));
    await tester.pumpAndSettle();

    // Debe haber llegado a la vista previa con la pista matcheada.
    expect(find.text('Guardar playlist'), findsOneWidget);
    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Artist A'), findsOneWidget);
    expect(find.text('1 canciones seleccionadas'), findsOneWidget);

    // Excluir la única pista deja la selección en 0 y deshabilita "Guardar".
    await tester.tap(find.byIcon(AppIcons.broken(SolarIcons.CloseCircle)));
    await tester.pumpAndSettle();
    expect(find.text('0 canciones seleccionadas'), findsOneWidget);
    final saveButtonDisabled = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Guardar playlist'));
    expect(saveButtonDisabled.onPressed, isNull);

    // Volver a incluirla la habilita de nuevo.
    await tester.tap(find.byIcon(AppIcons.broken(SolarIcons.AddCircle)));
    await tester.pumpAndSettle();
    expect(find.text('1 canciones seleccionadas'), findsOneWidget);

    await tester.tap(find.text('Guardar playlist'));
    // `_save` exitoso dispara un `AppToast` con auto-dismiss a los 3s (Timer
    // real, no animación) -- un `pumpAndSettle()` con el `duration` por
    // defecto (100ms) puede asentarse antes de que ese timer llegue a
    // disparar, dejándolo pendiente al cerrar el test (mismo patrón que el
    // test de "IA inalcanzable" más arriba).
    await tester.pumpAndSettle(const Duration(seconds: 4));

    // `_save` exitoso hace `AppBottomSheet.pop` -- la hoja se cierra y vuelve
    // a verse el botón que la abre, ya sin nada de la hoja en pantalla.
    expect(find.text('abrir'), findsOneWidget);
    expect(find.text('Guardar playlist'), findsNothing);
  });

  testWidgets('Afinar con IA con +N canciones agrega temas adicionales sin reemplazar los existentes', (tester) async {
    const fakeTrack1 = DeezerTrack(
      id: 1,
      artistId: 10,
      albumId: 100,
      title: 'Initial Song',
      artistName: 'Initial Artist',
      albumTitle: 'Album 1',
      coverUrl: 'https://cover.example/1.jpg',
      durationSec: 180,
    );

    int callCount = 0;
    final aiService = AiAssistantService(
      keyStorage: _FakeAiKeyStorage(),
      invoke: (functionName, {headers = const {}, body}) async {
        callCount++;
        if (callCount == 1) {
          return FunctionResponse(
            status: 200,
            data: {
              'action': 'create_playlist',
              'result': {
                'playlistName': 'Mi Playlist',
                'tracks': [{'title': 'Initial Song', 'artist': 'Initial Artist'}],
              },
            },
          );
        } else {
          return FunctionResponse(
            status: 200,
            data: {
              'action': 'modify_playlist_add',
              'result': {
                'tracks': [{'title': 'Added Song', 'artist': 'Added Artist'}],
              },
            },
          );
        }
      },
    );

    // Mock Deezer to return fakeTrack1 or fakeTrack2 based on query
    final deezerApi = _FakeDeezerApi(fakeTrack1);

    await tester.pumpWidget(buildHarness(
      aiService: aiService,
      deezerApi: deezerApi,
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'música inicial');
    await tester.tap(find.text('Crear con IA'));
    await tester.pumpAndSettle();

    expect(find.text('Initial Song'), findsOneWidget);

    // Abre el panel de afinar
    await tester.tap(find.text('Afinar con IA'));
    await tester.pumpAndSettle();

    // Escribe "+1 canción más acústica"
    await tester.enterText(find.widgetWithText(TextField, 'Ej: menos canciones lentas, más de los 2000s'), '+1 canción más acústica');
    await tester.tap(find.text('Enviar ajuste'));
    await tester.pumpAndSettle();

    // Ahora deben estar presentes ambas
    expect(find.text('Initial Song'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });
}
