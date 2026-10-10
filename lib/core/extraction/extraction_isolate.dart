import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';

import 'dart_fetch_bridge.dart';
import 'engine/engine_bundle.dart';
import 'models/extraction_request.dart';
import 'models/extraction_result.dart';
import 'retry_policy.dart';
import 'yt_search_matcher.dart';

class _IsolateInitMessage {
  final RootIsolateToken token;
  final SendPort mainSendPort;
  final String jsBundle;

  _IsolateInitMessage({
    required this.token,
    required this.mainSendPort,
    required this.jsBundle,
  });
}

class ExtractionLogMessage {
  final String message;
  ExtractionLogMessage(this.message);
}

/// Resultado de evaluar un motor en QuickJS (Fase 8.A).
///
/// Antes, si el motor no compilaba, el isolate solo escribía un log y cada
/// extracción posterior fallaba con un `extractVideo is not defined` que la
/// app trataba como "canción no disponible". Ahora el isolate lo informa al
/// arrancar y el `EngineManager` puede volver a otro motor.
class EngineLoadReport {
  final bool ok;
  final String? error;
  final int? build;
  final String? youtubei;
  final List<String> clients;

  const EngineLoadReport({
    required this.ok,
    this.error,
    this.build,
    this.youtubei,
    this.clients = kDefaultEngineClients,
  });
}

/// Búsqueda de canciones en YouTube Music por texto libre (2026-10-08, la
/// "búsqueda por letra"): YouTube Music indexa las letras, y con un fragmento
/// devuelve la canción en el primer lugar casi siempre (medido: 12 de 13
/// fragmentos). Usa el `searchVideos(..., 'music')` que el motor ya expone,
/// así que no cambia el motor OTA.
class MusicSearchRequest {
  final String requestId;
  final String query;
  const MusicSearchRequest({required this.requestId, required this.query});
}

/// Filas `{videoId, title, author, durationSec}` de YouTube Music, o
/// [error] si la búsqueda no obtuvo respuesta.
class MusicSearchResponse {
  final String requestId;
  final List<Map<String, dynamic>> results;
  final String? error;
  const MusicSearchResponse({required this.requestId, this.results = const [], this.error});
}

final Map<String, Completer<Map<String, dynamic>>> _jsExtractCompleters = {};
final Map<String, Completer<Map<String, dynamic>>> _jsSearchCompleters = {};
final Map<String, String> _resolvedMatchCache = {};

/// Isolate de extracción que vive durante toda la sesión de la app.
/// Ejecuta QuickJS (flutter_js) en background sin congelar la UI (Pitfall #8).
class ExtractionIsolate {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  final Map<String, Completer<ExtractionResult>> _pendingRequests = {};
  final Map<String, Completer<MusicSearchResponse>> _pendingSearches = {};
  ReceivePort? _mainReceivePort;
  ReceivePort? _exitPort;
  Completer<EngineLoadReport>? _spawnCompleter;
  Completer<void>? _reloading;
  final StreamController<String> _logController = StreamController<String>.broadcast();

  Stream<String> get onLogMessage => _logController.stream;
  bool get isInitialized => _isolateSendPort != null;

  /// Arranca el isolate con [bundle] y espera a que QuickJS lo evalúe.
  /// Si ya está arrancado (o arrancando), devuelve ese mismo arranque.
  Future<EngineLoadReport> spawn(EngineBundle bundle) async {
    final inFlight = _spawnCompleter;
    if (inFlight != null) return inFlight.future;

    final completer = Completer<EngineLoadReport>();
    _spawnCompleter = completer;

    final token = RootIsolateToken.instance;
    if (token == null) {
      _spawnCompleter = null;
      throw StateError('RootIsolateToken no está disponible.');
    }

    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    _mainReceivePort = receivePort;
    _exitPort = exitPort;

    receivePort.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
      } else if (message is EngineLoadReport) {
        if (!completer.isCompleted) completer.complete(message);
      } else if (message is ExtractionResult) {
        final pending = _pendingRequests.remove(message.requestId);
        pending?.complete(message);
      } else if (message is MusicSearchResponse) {
        _pendingSearches.remove(message.requestId)?.complete(message);
      } else if (message is ExtractionLogMessage) {
        _logController.add(message.message);
      }
    });

    // H-8-3: si el isolate muere (excepción no capturada), antes nadie se
    // enteraba y las peticiones pendientes no se completaban nunca: la
    // canción se quedaba "cargando" para siempre. Ahora se completan con
    // error de red (el reproductor reintenta 1 vez) y la siguiente petición
    // vuelve a arrancar el motor.
    exitPort.listen((_) {
      if (!identical(_exitPort, exitPort)) return; // muerte esperada (reload/dispose)
      _logController.add('[IsolateJS] El isolate de extracción terminó inesperadamente.');
      _teardown();
      if (!completer.isCompleted) {
        completer.complete(const EngineLoadReport(ok: false, error: 'El isolate terminó al arrancar'));
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _isolateEntryPoint,
        _IsolateInitMessage(
          token: token,
          mainSendPort: receivePort.sendPort,
          jsBundle: bundle.code,
        ),
        onExit: exitPort.sendPort,
      );
    } catch (e) {
      _teardown();
      rethrow;
    }

    final report = await completer.future;
    if (identical(_spawnCompleter, completer)) _spawnCompleter = null;
    return report;
  }

  Future<ExtractionResult> request(ExtractionRequest request) async {
    final reloading = _reloading;
    if (reloading != null) await reloading.future;
    final port = _isolateSendPort;
    if (port == null) {
      return ExtractionFailure(
        requestId: request.requestId,
        error: ExtractionError.networkError,
        message: 'El motor de extracción no está disponible.',
      );
    }

    final completer = Completer<ExtractionResult>();
    _pendingRequests[request.requestId] = completer;
    port.send(request);
    return completer.future;
  }

  /// Busca [query] en el catálogo de canciones de YouTube Music. El isolate
  /// atiende un mensaje a la vez, así que espera a la extracción en curso.
  Future<MusicSearchResponse> searchMusic(String requestId, String query) async {
    final reloading = _reloading;
    if (reloading != null) await reloading.future;
    final port = _isolateSendPort;
    if (port == null) {
      return MusicSearchResponse(requestId: requestId, error: 'El motor de extracción no está disponible.');
    }
    final completer = Completer<MusicSearchResponse>();
    _pendingSearches[requestId] = completer;
    port.send(MusicSearchRequest(requestId: requestId, query: query));
    return completer.future;
  }

  /// Cambia el motor en caliente (Fase 8.C, solo en emergencias): espera a
  /// que no haya extracciones en curso (máx. [drainTimeout]), mata el isolate
  /// y arranca otro con [bundle]. Las peticiones que lleguen mientras tanto
  /// esperan al motor nuevo.
  Future<EngineLoadReport> reload(
    EngineBundle bundle, {
    Duration drainTimeout = const Duration(seconds: 30),
  }) async {
    final gate = Completer<void>();
    _reloading = gate;
    try {
      final deadline = DateTime.now().add(drainTimeout);
      while (_pendingRequests.isNotEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _teardown();
      return await spawn(bundle);
    } finally {
      _reloading = null;
      gate.complete();
    }
  }

  void resetEngine() {
    _isolateSendPort?.send('RESET_ENGINE');
  }

  /// Mata el isolate actual y completa con error lo que quedara pendiente.
  void _teardown() {
    _exitPort?.close();
    _exitPort = null;
    _mainReceivePort?.close();
    _mainReceivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
    _spawnCompleter = null;
    final orphanedSearches = Map.of(_pendingSearches);
    _pendingSearches.clear();
    for (final entry in orphanedSearches.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(MusicSearchResponse(requestId: entry.key, error: 'El motor de extracción se reinició.'));
      }
    }
    final orphaned = Map.of(_pendingRequests);
    _pendingRequests.clear();
    for (final entry in orphaned.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(ExtractionFailure(
          requestId: entry.key,
          error: ExtractionError.networkError,
          message: 'El motor de extracción se reinició.',
        ));
      }
    }
  }

  void dispose() {
    _teardown();
    _logController.close();
  }

  /// Punto de entrada del Isolate secundario
  static void _isolateEntryPoint(_IsolateInitMessage initMessage) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(initMessage.token);

    final childReceivePort = ReceivePort();
    initMessage.mainSendPort.send(childReceivePort.sendPort);

    void sendLog(String msg) {
      // `dev.log` desde un isolate secundario NO llega a la terminal de
      // `flutter run` (solo a DevTools), así que todos estos mensajes eran
      // invisibles en la práctica — a diferencia de los `[JS] ...`, que los
      // imprime QuickJS directo a stdout. `debugPrint` sí sale en la
      // terminal, que es donde se depura de verdad.
      dev.log(msg);
      debugPrint(msg);
      initMessage.mainSendPort.send(ExtractionLogMessage(msg));
    }

    final fetchBridge = DartFetchBridge();
    final retryPolicy = RetryPolicy();

    JavascriptRuntime? jsRuntime;
    Timer? pendingJobTimer;
    var loadReport = const EngineLoadReport(ok: false, error: 'El motor no cargó');

    try {
      jsRuntime = getJavascriptRuntime(xhr: false);

      // Canal consoleLog
      jsRuntime.onMessage('consoleLog', (dynamic args) {
        try {
          final Map<String, dynamic> data = args is Map
              ? Map<String, dynamic>.from(args)
              : jsonDecode(args.toString());
          sendLog('[IsolateJS:${data['type']}] ${data['message']}');
        } catch (_) {
          sendLog('[IsolateJS:log] $args');
        }
      });

      // Canal setTimeout
      jsRuntime.onMessage('setTimeout', (dynamic args) {
        try {
          final Map<String, dynamic> data = args is Map
              ? Map<String, dynamic>.from(args)
              : jsonDecode(args.toString());
          final int id = data['id'];
          final int delay = data['delay'] ?? 0;
          Future.delayed(Duration(milliseconds: delay), () {
            jsRuntime?.evaluate('globalThis.__fireTimeout($id);');
            jsRuntime?.executePendingJob();
          });
        } catch (e) {
          sendLog('[IsolateJS] Error en setTimeout: $e');
        }
      });

      // Canal dartFetch
      jsRuntime.onMessage('dartFetch', (dynamic args) async {
        try {
          final Map<String, dynamic> data = args is Map
              ? Map<String, dynamic>.from(args)
              : jsonDecode(args.toString());
          final int id = data['id'];
          final String url = data['url'];
          final String method = data['method'] ?? 'GET';
          final Map<String, dynamic>? headers = data['headers'] != null
              ? Map<String, dynamic>.from(data['headers'])
              : null;
          final dynamic body = data['body'];

          sendLog('[dartFetch] req: $method $url');

          final res = await fetchBridge.fetch(
            url: url,
            method: method,
            headers: headers,
            body: body,
          );

          sendLog('[dartFetch] res: ${res.statusCode} ${res.statusText} para $url');

          final headersJson = jsonEncode(res.headers);
          final escapedBody = jsonEncode(res.bodyText);

          final script =
              'globalThis.__dartFetchResponse($id, ${res.statusCode}, ${jsonEncode(res.statusText)}, $headersJson, $escapedBody, null);';
          final evalRes = jsRuntime?.evaluate(script);
          if (evalRes?.isError == true) {
             sendLog('[dartFetch] JS ERROR evaluating __dartFetchResponse: ${evalRes?.stringResult}');
          }
          jsRuntime?.executePendingJob();
        } catch (err) {
          sendLog('[dartFetch ERROR] $err');
          try {
            final data = jsonDecode(args.toString());
            final int id = data['id'];
            final script =
                'globalThis.__dartFetchResponse($id, 500, "Error", "{}", "", ${jsonEncode(err.toString())});';
            jsRuntime?.evaluate(script);
            jsRuntime?.executePendingJob();
          } catch (_) {}
        }
      });

      // Canal extractionResult
      jsRuntime.onMessage('extractionResult', (dynamic args) {
        try {
          final Map<String, dynamic> data = args is Map
              ? Map<String, dynamic>.from(args)
              : jsonDecode(args.toString());
          final String? jsRequestId = data['requestId'];
          if (jsRequestId != null) {
            final completer = _jsExtractCompleters.remove(jsRequestId);
            completer?.complete(data);
          }
        } catch (e) {
          sendLog('[IsolateJS] Error al parsear extractionResult: $e\nDatos originales: $args');
        }
      });

      // Canal searchResult
      jsRuntime.onMessage('searchResult', (dynamic args) {
        try {
          final Map<String, dynamic> data = args is Map
              ? Map<String, dynamic>.from(args)
              : jsonDecode(args.toString());
          final String? jsRequestId = data['requestId'];
          if (jsRequestId != null) {
            final completer = _jsSearchCompleters.remove(jsRequestId);
            completer?.complete(data);
          }
        } catch (e) {
          sendLog('[IsolateJS] Error al parsear searchResult: $e\nDatos originales: $args');
        }
      });

      // Evaluar el motor (polyfills + youtubei.js + pegamento) y comprobar
      // que expone el contrato (Fase 8.A).
      sendLog('[IsolateJS] Cargando motor en QuickJS...');
      final bundleRes = jsRuntime.evaluate(initMessage.jsBundle);
      jsRuntime.executePendingJob();
      if (bundleRes.isError) {
        loadReport = EngineLoadReport(ok: false, error: 'El motor no compila: ${bundleRes.stringResult}');
      } else {
        loadReport = _readEngineContract(jsRuntime);
      }
    } catch (e) {
      loadReport = EngineLoadReport(ok: false, error: 'Error al inicializar QuickJS: $e');
    }

    if (loadReport.ok) {
      sendLog('[IsolateJS] Motor ${loadReport.build} cargado (youtubei.js ${loadReport.youtubei}, '
          'clientes ${loadReport.clients.join(", ")}).');
    } else {
      sendLog('[IsolateJS ERROR CRÍTICO] ${loadReport.error}');
    }
    initMessage.mainSendPort.send(loadReport);

    // Bombeo de la cola de trabajos de QuickJS (promesas), **solo mientras se
    // atiende una petición**. Antes era un `Timer.periodic` de 50 ms que no se
    // apagaba nunca: 20 despertares por segundo con la app en reposo, buena
    // parte del 5-6 % de CPU que se veía en Windows. Fuera de una petición no
    // hace falta: las respuestas de `dartFetch` y los `setTimeout` ya llaman
    // a `executePendingJob` al llegar. Las peticiones se atienden de una en
    // una (`await for`), así que no hay solapamiento que cuidar.
    Future<T> withJobPump<T>(Future<T> Function() work) async {
      pendingJobTimer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
        jsRuntime?.executePendingJob();
      });
      try {
        return await work();
      } finally {
        pendingJobTimer?.cancel();
        pendingJobTimer = null;
        jsRuntime?.executePendingJob();
      }
    }

    // Escuchar peticiones enviadas desde el Main Isolate
    await for (final message in childReceivePort) {
      if (message is ExtractionRequest) {
        final ExtractionResult result;
        if (!loadReport.ok) {
          // Sin motor no hay nada que intentar: fallar rápido y marcado como
          // problema del motor, nunca como "canción no disponible".
          result = ExtractionFailure(
            requestId: message.requestId,
            error: ExtractionError.unknownError,
            message: 'El motor no cargó: ${loadReport.error}',
            suspectEngine: true,
          );
        } else {
          result = await withJobPump(() => _processExtraction(
                request: message,
                jsRuntime: jsRuntime,
                retryPolicy: retryPolicy,
                sendLog: sendLog,
                clients: loadReport.clients,
              ));
        }
        initMessage.mainSendPort.send(result);
      } else if (message is MusicSearchRequest) {
        if (!loadReport.ok) {
          initMessage.mainSendPort.send(MusicSearchResponse(
            requestId: message.requestId,
            error: 'El motor no cargó: ${loadReport.error}',
          ));
          continue;
        }
        final outcome = await withJobPump(() => _trySearchWithClient(
              query: message.query,
              client: 'WEB',
              jsRuntime: jsRuntime,
              sendLog: sendLog,
              mode: 'music',
            ));
        final results = outcome.results;
        initMessage.mainSendPort.send(MusicSearchResponse(
          requestId: message.requestId,
          results: [for (final r in results ?? const <Map<String, dynamic>>[]) Map<String, dynamic>.from(r)],
          error: results == null ? (outcome.jsError ?? 'YouTube Music no respondió') : null,
        ));
      } else if (message == 'RESET_ENGINE') {
        sendLog('[IsolateJS] Reiniciando motor JS...');
        jsRuntime?.evaluate('globalThis.resetJsEngine();');
        jsRuntime?.executePendingJob();
        retryPolicy.reset('');
        sendLog('[IsolateJS] Motor JS reiniciado.');
      }
    }
  }

  static Future<ExtractionResult> _processExtraction({
    required ExtractionRequest request,
    required JavascriptRuntime? jsRuntime,
    required RetryPolicy retryPolicy,
    required void Function(String) sendLog,
    List<String> clients = kDefaultEngineClients,
  }) async {
    final videoId = request.videoId.trim();

    if (videoId.startsWith('http://') || videoId.startsWith('https://')) {
      sendLog('[IsolateJS] Pista con URL directa de audio detectada: $videoId');
      return ExtractionSuccess(
        requestId: request.requestId,
        streamUrl: videoId,
        headers: const {},
      );
    }

    // C7: un id de Deezer numérico puede coincidir por longitud (11 dígitos)
    // a medida que crece el catálogo. Un id real de YouTube usa base64url y
    // es prácticamente imposible que salga puramente numérico — se excluye
    // ese caso para no tratar un id de Deezer como si ya fuera un video de
    // YouTube resuelto (saltándose el matcher por completo).
    final is11CharYtId = RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId) &&
        !RegExp(r'^[0-9]+$').hasMatch(videoId);
    if (!is11CharYtId) {
      final cachedVideoId = _resolvedMatchCache[videoId];
      if (cachedVideoId != null) {
        sendLog('[IsolateJS] Usando match en caché de memoria: $cachedVideoId para $videoId');
        final resolvedRequest = ExtractionRequest(
          videoId: cachedVideoId,
          requestId: request.requestId,
          priority: request.priority,
          trackTitle: request.trackTitle,
          trackArtist: request.trackArtist,
          durationSeconds: request.durationSeconds,
          quality: request.quality,
        );
        return _processExtraction(
          request: resolvedRequest,
          jsRuntime: jsRuntime,
          retryPolicy: retryPolicy,
          sendLog: sendLog,
          clients: clients,
        );
      }

      if ((request.trackTitle != null && request.trackTitle!.isNotEmpty) ||
          (request.trackArtist != null && request.trackArtist!.isNotEmpty)) {
        final rawArtist = request.trackArtist ?? '';
        final rawTitle = request.trackTitle ?? '';

        // C5: usar solo el artista principal en la query (no la lista con
        // comas de colaboradores — `DeezerTrack.artistName` las une así, y
        // esa cadena completa no es una búsqueda razonable), quitar sufijos
        // de versión tipo "- Remastered 2011", y no duplicar el artista si ya
        // aparece en el título.
        final primaryArtist = rawArtist.split(',').first.trim();
        final cleanTitle = _stripVersionSuffix(rawTitle);
        final artistAlreadyInTitle = primaryArtist.isNotEmpty &&
            YtSearchMatcher.norm(cleanTitle).contains(YtSearchMatcher.norm(primaryArtist));
        final baseQuery = (artistAlreadyInTitle || primaryArtist.isEmpty) ? cleanTitle : '$primaryArtist $cleanTitle';

        // Escalera de queries, de más específica a más laxa. El hint
        // "official audio" ayuda a dar con el upload oficial en temas
        // conocidos, pero en temas de nicho estrecha tanto la búsqueda que
        // apenas devuelve resultados — por eso hay un intento intermedio
        // SIN el hint pero CON el artista. El título pelado va al final y
        // solo como último recurso: para títulos genéricos (ej. "Antes De
        // Que Salga El Sol") devuelve sobre todo canciones homónimas de
        // otros artistas, así que no debe ser el segundo intento.
        final attempts = <(String query, String client, String mode)>[];
        void addAttempt(String q, String client, {String mode = 'video'}) {
          final t = q.trim();
          if (t.isEmpty) return;
          if (attempts.any((a) => a.$1 == t && a.$2 == client && a.$3 == mode)) return;
          attempts.add((t, client, mode));
        }

        // El orden importa y está calibrado contra el caso real que rompió:
        //  1. `artista título` en WEB es la que funcionaba antes de Fase C —
        //     va primero por ser la más fiable, no la más adornada.
        //  2. El hint "official audio" ayuda en temas conocidos pero estrecha
        //     demasiado en los de nicho, así que va después, no antes.
        //  3. ANDROID como cliente alterno: su parser falla ("Cannot cast
        //     SearchMobileHeader") y cae a un parseo crudo que pierde la
        //     duración, así que solo se usa si WEB no resolvió.
        //  4. Título pelado, último recurso y solo para el pase estricto.
        //  0. YouTube Music primero. Su catálogo son masters oficiales del
        //     sello por construcción (pistas auto-generadas, `musicVideoType`
        //     ATV), así que ahí no existen los karaokes ni los instrumentales
        //     re-subidos con un título de marketing — el caso "Ladders" no
        //     puede volver a ocurrir si la canción está en este catálogo.
        //     Medido contra la API en vivo: devuelve título, artista, álbum y
        //     duración exacta, y en 8 de 8 pruebas el primer resultado era el
        //     master correcto. **No es una petición extra**: en el caso común
        //     sustituye a la búsqueda de vídeos, que solo corre si de aquí no
        //     sale ningún candidato aceptable.
        addAttempt(baseQuery, 'WEB', mode: 'music');
        addAttempt(baseQuery, 'WEB');
        addAttempt('$baseQuery official audio', 'WEB');
        addAttempt(baseQuery, 'ANDROID');
        addAttempt(cleanTitle, 'WEB');

        // Los candidatos se ACUMULAN entre intentos (dedup por videoId) en
        // vez de reemplazarse: antes, si el primer intento traía el vídeo
        // correcto pero ninguno pasaba el umbral todavía, esos candidatos se
        // tiraban al pasar al siguiente intento. Ahora el ranking siempre ve
        // la unión de todo lo encontrado hasta el momento.
        final pool = <String, Map<String, dynamic>>{};
        // Lotes de resultados de queries que SÍ llevaban el nombre del
        // artista, en orden de especificidad. Solo estos alimentan el pase
        // relajado (C13): ahí no hay artista ni duración que corroboren, así
        // que la única evidencia que queda es que YouTube devolvió ese vídeo
        // *para una búsqueda que incluía al artista*. Mezclar los resultados
        // de la query de solo-título tiraba esa señal a la basura y hacía
        // ganar a un tema homónimo de otro artista.
        final artistBatches = <List<Map<String, dynamic>>>[];
        List<CandidateVideo> topCandidates = const [];

        final normPrimaryArtist = YtSearchMatcher.norm(primaryArtist);

        // Búsquedas que YouTube llegó a contestar (aunque fuera con cero
        // resultados). `null` en `_trySearchWithClient` es timeout o error:
        // si ninguna contestó, no sabemos si la canción existe, y devolver
        // `notFound` la saltaría y la marcaría "no disponible" el resto de la
        // sesión por un problema de red (visto al arrancar la app en Android,
        // con DNS todavía sin resolver).
        var answeredSearches = 0;
        // Fase 8.A: errores que devolvió el propio JS de búsqueda (el parser
        // reventó con YouTube contestando). Los de red se descartan: no dicen
        // nada del motor.
        final searchErrors = <String>[];

        // Ronda 5: videos que ya fallaron al extraerse (p. ej. el master de
        // YouTube Music que pide iniciar sesión) y siguiente búsqueda por
        // correr. Si todos los candidatos de una búsqueda fallan, se sigue con
        // la siguiente en vez de rendirse o de caer a uno de otro artista.
        final failedIds = <String>{};
        var nextAttempt = 0;

        Future<void> searchUntilCandidates() async {
        while (nextAttempt < attempts.length) {
          final attempt = attempts[nextAttempt++];
          final query = attempt.$1;
          final client = attempt.$2;
          final mode = attempt.$3;
          final sourceLabel = mode == 'music' ? 'YouTube Music' : 'cliente $client';
          sendLog('[IsolateJS] Buscando match para "$query" en $sourceLabel...');
          final outcome = await _trySearchWithClient(
            query: query,
            client: client,
            mode: mode,
            jsRuntime: jsRuntime,
            sendLog: sendLog,
          );
          final candidates = outcome.results;
          final searchError = outcome.jsError;
          if (searchError != null && _isSuspectEngineError(searchError)) {
            searchErrors.add(searchError);
          }
          if (candidates != null) answeredSearches++;
          if (candidates == null || candidates.isEmpty) {
            sendLog('[IsolateJS] Búsqueda sin candidatos en $sourceLabel.');
            continue;
          }

          final batch = <Map<String, dynamic>>[];
          for (final c in candidates) {
            final id = c['videoId'];
            if (id is String && id.isNotEmpty) {
              pool.putIfAbsent(id, () => c);
              batch.add(c);
            }
          }

          // Si la pista no trae artista conocido, no hay ninguna query "más
          // específica" que otra: todos los lotes son igual de buenos y
          // deben poder alimentar el pase relajado. Sin esta salvedad,
          // `artistBatches` quedaba vacío y el relajado no corría nunca,
          // dejando esas pistas sin reproducir.
          final bearsArtist = normPrimaryArtist.isEmpty ||
              YtSearchMatcher.norm(query).contains(normPrimaryArtist);
          if (bearsArtist && batch.isNotEmpty) artistBatches.add(batch);

          topCandidates = YtSearchMatcher.pickTopCandidates(
            pool.values.where((c) => !failedIds.contains(c['videoId'])).toList(),
            artist: rawArtist,
            title: rawTitle,
            durationSec: request.durationSeconds,
          );
          if (topCandidates.isNotEmpty) return;
          sendLog(
            '[IsolateJS] Ningún candidato superó el umbral de scoring (${pool.length} acumulados).',
          );
          // Volcado de lo que YouTube devolvió realmente: sin esto no hay
          // forma de saber si el vídeo correcto ni siquiera está entre los
          // candidatos o si está pero lo rechaza el umbral — la diferencia
          // entre "ajustar el scoring" y "buscar en otro sitio".
          var shown = 0;
          for (final c in batch) {
            if (shown++ >= 8) break;
            sendLog(
              '[IsolateJS]   cand: "${c['title']}" | canal="${c['author']}" '
              '| ${c['durationSec'] ?? "?"}s | ${c['videoId']}',
            );
          }
        }
        }

        await searchUntilCandidates();

        // C12: último recurso antes de rendirse. Sin esto, un tema de nicho
        // cuyo upload no confirma ni duración ni artista terminaba en
        // `notFound` -> auto-skip, y el usuario simplemente no podía
        // reproducirlo. El pase relajado exige más título a cambio de no
        // exigir corroboración, y sigue descartando karaokes/covers/directos
        // y duraciones muy distintas.
        if (topCandidates.isEmpty) {
          for (final batch in artistBatches) {
            final relaxedTop = YtSearchMatcher.pickTopCandidates(
              batch,
              artist: rawArtist,
              title: rawTitle,
              durationSec: request.durationSeconds,
              relaxed: true,
            );
            if (relaxedTop.isEmpty) continue;
            topCandidates = relaxedTop;
            final best = relaxedTop.first;
            sendLog(
              '[IsolateJS] Match RELAJADO (sin confirmar artista ni duración): '
              '${best.videoId} — "${best.title}" por "${best.author}" '
              '(${best.durationSec ?? "?"}s, esperado ${request.durationSeconds ?? "?"}s).',
            );
            break;
          }
        }

        // C6: probar el siguiente candidato si la extracción real del
        // primero falla por notFound (privado/geobloqueado/age-gate), en vez
        // de rendirse de inmediato. El caché de match resuelto solo se
        // escribe tras una extracción realmente exitosa — antes se escribía
        // apenas se elegía el candidato y nunca se invalidaba, así que un
        // match equivocado quedaba fijado el resto de la sesión.
        ExtractionFailure? lastCandidateFailure;
        while (true) {
        // Ronda 5: si el mejor candidato confirma al artista, solo se prueban
        // los que también lo confirman. Antes, si el master fallaba, se
        // probaba el siguiente de la lista aunque fuera de otro artista, y
        // así sonaba un cover ("Midnight City" de "Top 40 Hits").
        final anyConfirmed = topCandidates.any((c) => c.artistConfirmed);
        final round = [
          for (final c in topCandidates)
            if (!failedIds.contains(c.videoId) && (!anyConfirmed || c.artistConfirmed)) c,
        ];
        for (final candidate in round) {
          sendLog('[IsolateJS] Probando candidato ${candidate.videoId} (score ${candidate.score})...');
          final resolvedRequest = ExtractionRequest(
            videoId: candidate.videoId,
            requestId: request.requestId,
            priority: request.priority,
            trackTitle: request.trackTitle,
            trackArtist: request.trackArtist,
            durationSeconds: request.durationSeconds,
            quality: request.quality,
          );
          final result = await _processExtraction(
            request: resolvedRequest,
            jsRuntime: jsRuntime,
            retryPolicy: retryPolicy,
            sendLog: sendLog,
            clients: clients,
          );
          if (result is ExtractionSuccess) {
            _resolvedMatchCache[videoId] = candidate.videoId;
            return result;
          }
          if (result is ExtractionFailure && result.error != ExtractionError.notFound) {
            // Error distinto a "no encontrado" (red/rate-limit/desconocido):
            // no tiene sentido seguir probando otros candidatos ahora mismo.
            return result;
          }
          if (result is ExtractionFailure) lastCandidateFailure = result;
          failedIds.add(candidate.videoId);
          sendLog('[IsolateJS] Candidato ${candidate.videoId} no disponible, probando el siguiente...');
        }
        // Ninguno se pudo extraer: siguiente búsqueda, si queda alguna.
        if (round.isEmpty || nextAttempt >= attempts.length) {
          // Último recurso, ya sin búsquedas: los candidatos aceptados que el
          // filtro de "solo artista confirmado" dejó fuera (lo que se probaba
          // antes de la ronda 5). Mejor eso que saltar una canción de nicho
          // cuyo canal no se llama como el artista.
          final leftovers = [
            for (final c in topCandidates)
              if (!failedIds.contains(c.videoId)) c,
          ];
          for (final candidate in leftovers) {
            sendLog('[IsolateJS] Último recurso: candidato ${candidate.videoId} (score ${candidate.score})...');
            final result = await _processExtraction(
              request: ExtractionRequest(
                videoId: candidate.videoId,
                requestId: request.requestId,
                priority: request.priority,
                trackTitle: request.trackTitle,
                trackArtist: request.trackArtist,
                durationSeconds: request.durationSeconds,
                quality: request.quality,
              ),
              jsRuntime: jsRuntime,
              retryPolicy: retryPolicy,
              sendLog: sendLog,
              clients: clients,
            );
            if (result is ExtractionSuccess) {
              _resolvedMatchCache[videoId] = candidate.videoId;
              return result;
            }
            if (result is ExtractionFailure && result.error != ExtractionError.notFound) return result;
            if (result is ExtractionFailure) lastCandidateFailure = result;
            failedIds.add(candidate.videoId);
          }
          break;
        }
        sendLog('[IsolateJS] Ningún candidato se pudo extraer; se sigue con la siguiente búsqueda.');
        topCandidates = const [];
        await searchUntilCandidates();
        if (topCandidates.isEmpty) break;
        }

        // Había candidatos pero ninguno se pudo extraer, y por algo que apunta
        // al motor (no a vídeos privados o borrados).
        if (lastCandidateFailure != null && lastCandidateFailure.suspectEngine) {
          sendLog('[IsolateJS] Ningún candidato de "$videoId" se pudo extraer (posible fallo del motor).');
          return ExtractionFailure(
            requestId: request.requestId,
            error: ExtractionError.notFound,
            message: lastCandidateFailure.message,
            suspectEngine: true,
          );
        }

        if (topCandidates.isEmpty && answeredSearches == 0 && searchErrors.isNotEmpty) {
          // YouTube contestó pero el JS de búsqueda no supo leer la respuesta:
          // es el motor, no la red ni la canción.
          sendLog('[IsolateJS] Todas las búsquedas fallaron dentro del motor: ${searchErrors.first}');
          return ExtractionFailure(
            requestId: request.requestId,
            error: ExtractionError.unknownError,
            message: 'La búsqueda de YouTube falló: ${searchErrors.first}',
            suspectEngine: true,
          );
        }

        if (topCandidates.isEmpty && answeredSearches == 0) {
          sendLog(
            '[IsolateJS] Ninguna búsqueda obtuvo respuesta para "$rawArtist - $rawTitle" '
            '(${attempts.length} intentos). Se trata como error de red, no como "no encontrada".',
          );
          return ExtractionFailure(
            requestId: request.requestId,
            error: ExtractionError.networkError,
            message: 'No se pudo conectar con YouTube. Revisa tu conexión.',
          );
        }

        if (topCandidates.isEmpty) {
          sendLog(
            '[IsolateJS] Ningún candidato aceptable para "$rawArtist - $rawTitle" '
            '(${pool.length} vistos en ${attempts.length} búsquedas). '
            'La pista se saltará.',
          );
        }
      }

      sendLog('[IsolateJS] Pista no-YouTube "$videoId" sin coincidencia válida -> notFound');
      return ExtractionFailure(
        requestId: request.requestId,
        error: ExtractionError.notFound,
      );
    }

    String lastJsError = '';

    for (final client in clients) {
      sendLog('[IsolateJS] Probando cliente Innertube: $client para videoId: ${request.videoId}...');
      try {
        final evalResult = await _tryExtractWithClient(
          videoId: request.videoId,
          client: client,
          jsRuntime: jsRuntime,
          sendLog: sendLog,
          quality: request.quality,
        );

        if (evalResult != null) {
          if (evalResult['url'] != null) {
            sendLog('[IsolateJS] Extracción exitosa con cliente: $client!');
            retryPolicy.reset(request.videoId);
            final rawUrl = evalResult['url'];
            final String streamUrl = rawUrl is Map ? (rawUrl['url']?.toString() ?? rawUrl.toString()) : rawUrl.toString();
            return ExtractionSuccess(
              requestId: request.requestId,
              streamUrl: streamUrl,
              headers: Map<String, String>.from(evalResult['headers'] ?? {}),
            );
          } else if (evalResult['error'] != null) {
            lastJsError = evalResult['error'].toString();
            sendLog('[IsolateJS] Cliente $client falló de forma controlada: $lastJsError');
          }
        }
      } catch (e) {
        lastJsError = e.toString();
        sendLog('[IsolateJS] Excepción en cliente $client: $e');
      }
    }

    // Clasificar la causa real del fallo para aplicar el guard correctamente
    // (Pitfalls #11 y #14). Antes esto se forzaba a `rateLimited`, lo que
    // provocaba que errores lógicos (metadata ausente) se reintentaran.
    final errorType = _classifyExtractionError(lastJsError);

    // Solo 403/red pueden reintentarse (máx. 1 vez). Los errores lógicos y
    // desconocidos fallan de inmediato (fail fast / auto-skip).
    if (errorType == ExtractionError.rateLimited ||
        errorType == ExtractionError.networkError) {
      if (retryPolicy.canRetry(request.videoId, errorType)) {
        sendLog('[IsolateJS] Guard 403: Reintentando extracción (1 reintento permitido)...');
        await Future.delayed(const Duration(seconds: 2));
        return _processExtraction(
          request: request,
          jsRuntime: jsRuntime,
          retryPolicy: retryPolicy,
          sendLog: sendLog,
          clients: clients,
        );
      }
      sendLog('[IsolateJS] Guard 403: Pausando reproductor. No se pudo extraer la URL.');
    } else {
      sendLog('[IsolateJS] Fallo lógico ($errorType): abortando sin reintento.');
    }

    return ExtractionFailure(
      requestId: request.requestId,
      error: errorType,
      message: 'No se pudo extraer la URL con clientes ($clients). Detalle: $lastJsError',
      // Fase 8.A: YouTube contestó en todos los clientes y aun así no hubo
      // URL, y no por un vídeo privado/borrado: apunta al motor.
      suspectEngine: (errorType == ExtractionError.notFound || errorType == ExtractionError.unknownError) &&
          _isSuspectEngineError(lastJsError),
    );
  }

  /// Lee `SYNCORA_ENGINE` y comprueba que el motor expone el contrato que
  /// espera este isolate (`kSupportedEngineApi`).
  static EngineLoadReport _readEngineContract(JavascriptRuntime js) {
    final res = js.evaluate('JSON.stringify({'
        'extract: typeof globalThis.extractVideo === "function",'
        'search: typeof globalThis.searchVideos === "function",'
        'info: globalThis.SYNCORA_ENGINE || null})');
    if (res.isError) {
      return EngineLoadReport(ok: false, error: 'No se pudo leer el contrato: ${res.stringResult}');
    }
    try {
      final data = jsonDecode(res.stringResult) as Map<String, dynamic>;
      if (data['extract'] != true || data['search'] != true) {
        return const EngineLoadReport(ok: false, error: 'El motor no expone extractVideo/searchVideos');
      }
      final info = data['info'] is Map ? Map<String, dynamic>.from(data['info'] as Map) : null;
      final api = (info?['api'] as num?)?.toInt();
      if (info != null && api != kSupportedEngineApi) {
        return EngineLoadReport(ok: false, error: 'Motor de api $api, esta app entiende la $kSupportedEngineApi');
      }
      final rawClients = info?['clients'];
      final clients = rawClients is List && rawClients.isNotEmpty
          ? rawClients.map((c) => c.toString()).toList()
          : kDefaultEngineClients;
      return EngineLoadReport(
        ok: true,
        build: (info?['build'] as num?)?.toInt(),
        youtubei: info?['youtubei'] as String?,
        clients: clients,
      );
    } catch (e) {
      return EngineLoadReport(ok: false, error: 'Contrato ilegible: $e');
    }
  }

  /// ¿Este error apunta al motor? No si es de red/403 (lo cubre el guard de
  /// reintentos) ni si es un vídeo concreto que ya no existe o es privado.
  static bool _isSuspectEngineError(String errorText) {
    final type = _classifyExtractionError(errorText);
    if (type == ExtractionError.networkError || type == ExtractionError.rateLimited) return false;
    final e = errorText.toLowerCase();
    if (e.contains('dioexception') || e.contains('connection')) return false;
    const contentMarkers = ['private video', 'video unavailable', 'no longer available'];
    return !contentMarkers.any(e.contains);
  }

  /// Clasifica el texto de error devuelto por QuickJS en un [ExtractionError].
  ///
  /// - [notFound]: errores lógicos (metadata ausente, video privado/no
  ///   disponible). Candidatos a auto-skip; NO se reintentan.
  /// - [rateLimited]: errores 403 / Forbidden / baneo de BotGuard.
  /// - [networkError]: problemas de red (timeout, SocketException).
  /// - [unknownError]: cualquier otra causa.
  static ExtractionError _classifyExtractionError(String errorText) {
    final e = errorText.toLowerCase();

    // Fase 8: YouTube bloqueó la IP ("Sign in to confirm you're not a bot").
    // Va ANTES que los lógicos porque llega envuelto en "Streaming data not
    // available": no es la canción, así que saltar vaciaría la cola entera
    // (Pitfall #14). Pausa como un 403. Ojo: "confirm your age" (restricción
    // de edad) sí es de la canción y sigue siendo notFound.
    const ipBlockMarkers = ['not a bot', 'unusual traffic'];
    for (final marker in ipBlockMarkers) {
      if (e.contains(marker)) return ExtractionError.rateLimited;
    }

    // Errores lógicos: la canción existe pero no hay streaming utilizable,
    // o el video no existe / es privado. Reintentar no sirve de nada.
    const notFoundMarkers = [
      'streaming data not available',
      'no se encontró ningún formato',
      'no se encontró un formato',
      'no se pudo determinar la url',
      'no se pudo obtener url',
      'ningún formato',
      'video unavailable',
      'private video',
      'not available',
      'no longer available',
    ];
    for (final marker in notFoundMarkers) {
      if (e.contains(marker)) return ExtractionError.notFound;
    }

    // Baneo / BotGuard: YouTube bloqueó la petición (403).
    const rateLimitedMarkers = ['403', 'forbidden', 'botguard', 'rate limit', 'rate-limit'];
    for (final marker in rateLimitedMarkers) {
      if (e.contains(marker)) return ExtractionError.rateLimited;
    }

    // Red: timeout o problemas de conectividad.
    const networkMarkers = ['timeout', 'socketexception', 'connection refused', 'connection reset', 'failed host lookup'];
    for (final marker in networkMarkers) {
      if (e.contains(marker)) return ExtractionError.networkError;
    }

    return ExtractionError.unknownError;
  }

  // C5: sufijos de versión ("- Remastered 2011", "(Remaster 2009)") no
  // ayudan a la búsqueda en YouTube y a veces la empeoran (el upload rara vez
  // repite el año del remaster en el título).
  static final RegExp _versionSuffix = RegExp(
    r'\s*[\(\[-]\s*(re)?master(ed)?(\s*\d{4})?\s*[\)\]]?\s*$',
    caseSensitive: false,
  );

  static String _stripVersionSuffix(String title) => title.replaceAll(_versionSuffix, '').trim();

  static Future<Map<String, dynamic>?> _tryExtractWithClient({
    required String videoId,
    required String client,
    required JavascriptRuntime? jsRuntime,
    required void Function(String) sendLog,
    String? quality,
  }) async {
    if (jsRuntime == null) return null;

    final jsRequestId = 'js_${DateTime.now().microsecondsSinceEpoch}_${videoId}_$client';
    final completer = Completer<Map<String, dynamic>>();
    _jsExtractCompleters[jsRequestId] = completer;

    // C7: `jsonEncode` en vez de interpolación cruda — antes solo comillas
    // simples sin escapar en absoluto; un id/valor con un apóstrofe literal
    // rompía la sintaxis del script generado.
    final code =
        'globalThis.extractVideo(${jsonEncode(videoId)}, ${jsonEncode(client)}, ${jsonEncode(jsRequestId)}, ${jsonEncode(quality ?? "high")});';
    final evalRes = jsRuntime.evaluate(code);
    
    if (evalRes.isError) {
      sendLog('[IsolateJS ERROR AL EJECUTAR EXTRACTVIDEO] ${evalRes.stringResult}');
      _jsExtractCompleters.remove(jsRequestId);
      return {'error': 'Error sintáctico en extractVideo: ${evalRes.stringResult}'};
    }

    jsRuntime.executePendingJob();

    try {
      return await completer.future.timeout(const Duration(seconds: 25));
    } catch (e) {
      _jsExtractCompleters.remove(jsRequestId);
      sendLog('[IsolateJS] Timeout en extractVideo para $client');
      return {'error': 'Timeout o error esperando respuesta de QuickJS: $e'};
    }
  }

  /// `results` es `null` si la búsqueda no obtuvo respuesta utilizable;
  /// `jsError` trae el error que devolvió el propio JS, si lo hubo.
  static Future<({List<Map<String, dynamic>>? results, String? jsError})> _trySearchWithClient({
    required String query,
    required String client,
    required JavascriptRuntime? jsRuntime,
    required void Function(String) sendLog,
    String mode = 'video',
  }) async {
    if (jsRuntime == null) return (results: null, jsError: 'El motor no cargó');

    final jsRequestId = 'js_search_${DateTime.now().microsecondsSinceEpoch}_${client}_$mode';
    final completer = Completer<Map<String, dynamic>>();
    _jsSearchCompleters[jsRequestId] = completer;

    // C7: `jsonEncode` en vez de escapar a mano solo comillas simples (no
    // cubría backslashes, comillas dobles ni saltos de línea en el título).
    final code =
        'globalThis.searchVideos(${jsonEncode(query)}, ${jsonEncode(client)}, '
        '${jsonEncode(jsRequestId)}, ${jsonEncode(mode)});';
    final evalRes = jsRuntime.evaluate(code);

    if (evalRes.isError) {
      sendLog('[IsolateJS ERROR AL EJECUTAR SEARCHVIDEOS] ${evalRes.stringResult}');
      _jsSearchCompleters.remove(jsRequestId);
      return (results: null, jsError: 'Error sintáctico en searchVideos: ${evalRes.stringResult}');
    }

    jsRuntime.executePendingJob();

    try {
      final res = await completer.future.timeout(const Duration(seconds: 20));
      if (res.containsKey('results') && res['results'] is List) {
        return (results: (res['results'] as List).cast<Map<String, dynamic>>(), jsError: null);
      }
      if (res.containsKey('error')) {
        sendLog('[IsolateJS] searchVideos $client/$mode devolvió error: ${res['error']}');
        return (results: null, jsError: res['error'].toString());
      }
      return (results: null, jsError: null);
    } catch (e) {
      _jsSearchCompleters.remove(jsRequestId);
      sendLog('[IsolateJS] Timeout en searchVideos para $client/$mode');
      return (results: null, jsError: null);
    }
  }
}
