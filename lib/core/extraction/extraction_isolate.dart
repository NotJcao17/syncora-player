import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';

import 'dart_fetch_bridge.dart';
import 'js_bundle_loader.dart';
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

final Map<String, Completer<Map<String, dynamic>>> _jsExtractCompleters = {};
final Map<String, Completer<Map<String, dynamic>>> _jsSearchCompleters = {};
final Map<String, String> _resolvedMatchCache = {};

/// Isolate de extracción que vive durante toda la sesión de la app.
/// Ejecuta QuickJS (flutter_js) en background sin congelar la UI (Pitfall #8).
class ExtractionIsolate {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  final Map<String, Completer<ExtractionResult>> _pendingRequests = {};
  ReceivePort? _mainReceivePort;
  Completer<void>? _spawnCompleter;
  final StreamController<String> _logController = StreamController<String>.broadcast();

  Stream<String> get onLogMessage => _logController.stream;
  bool get isInitialized => _isolateSendPort != null;

  Future<void> spawn() async {
    if (isInitialized) return;
    if (_spawnCompleter != null) return _spawnCompleter!.future;

    _spawnCompleter = Completer<void>();

    final token = RootIsolateToken.instance;
    if (token == null) {
      _spawnCompleter = null;
      throw StateError('RootIsolateToken no está disponible.');
    }

    final jsBundle = await JsBundleLoader.loadCompleteBundle();
    _mainReceivePort = ReceivePort();

    _mainReceivePort!.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
        if (!(_spawnCompleter?.isCompleted ?? true)) {
          _spawnCompleter?.complete();
        }
      } else if (message is ExtractionResult) {
        final completer = _pendingRequests.remove(message.requestId);
        completer?.complete(message);
      } else if (message is ExtractionLogMessage) {
        _logController.add(message.message);
      }
    });

    _isolate = await Isolate.spawn(
      _isolateEntryPoint,
      _IsolateInitMessage(
        token: token,
        mainSendPort: _mainReceivePort!.sendPort,
        jsBundle: jsBundle,
      ),
    );

    return _spawnCompleter!.future;
  }

  Future<ExtractionResult> request(ExtractionRequest request) async {
    if (_isolateSendPort == null) {
      await spawn();
    }

    final completer = Completer<ExtractionResult>();
    _pendingRequests[request.requestId] = completer;

    _isolateSendPort!.send(request);

    return completer.future;
  }

  void resetEngine() {
    _isolateSendPort?.send('RESET_ENGINE');
  }

  void dispose() {
    _logController.close();
    _mainReceivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
    _spawnCompleter = null;
  }

  /// Punto de entrada del Isolate secundario
  static void _isolateEntryPoint(_IsolateInitMessage initMessage) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(initMessage.token);

    final childReceivePort = ReceivePort();
    initMessage.mainSendPort.send(childReceivePort.sendPort);

    void sendLog(String msg) {
      dev.log(msg);
      initMessage.mainSendPort.send(ExtractionLogMessage(msg));
    }

    final fetchBridge = DartFetchBridge();
    final retryPolicy = RetryPolicy();

    JavascriptRuntime? jsRuntime;
    Timer? pendingJobTimer;

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

      // Asegurar que el microtask queue se procese constantemente
      pendingJobTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        jsRuntime?.executePendingJob();
      });

      // Evaluar bundle de polyfills + youtubei.js
      sendLog('[IsolateJS] Cargando bundle QuickJS...');
      final bundleRes = jsRuntime.evaluate(initMessage.jsBundle);
      if (bundleRes.isError) {
        sendLog('[IsolateJS ERROR CRÍTICO] Falló compilación del bundle JS: ${bundleRes.stringResult}');
      } else {
        sendLog('[IsolateJS] Bundle QuickJS cargado con éxito.');
      }
    } catch (e) {
      sendLog('[IsolateJS] Error al inicializar QuickJS: $e');
    }

    // Escuchar peticiones enviadas desde el Main Isolate
    await for (final message in childReceivePort) {
      if (message is ExtractionRequest) {
        final result = await _processExtraction(
          request: message,
          jsRuntime: jsRuntime,
          retryPolicy: retryPolicy,
          sendLog: sendLog,
        );
        initMessage.mainSendPort.send(result);
      } else if (message == 'RESET_ENGINE') {
        sendLog('[IsolateJS] Reiniciando motor JS...');
        pendingJobTimer?.cancel();
        jsRuntime?.evaluate('globalThis.resetJsEngine();');
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

    final is11CharYtId = RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId);
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
        );
        return _processExtraction(
          request: resolvedRequest,
          jsRuntime: jsRuntime,
          retryPolicy: retryPolicy,
          sendLog: sendLog,
        );
      }

      if ((request.trackTitle != null && request.trackTitle!.isNotEmpty) ||
          (request.trackArtist != null && request.trackArtist!.isNotEmpty)) {
        final query = '${request.trackArtist ?? ''} ${request.trackTitle ?? ''}'.trim();
        for (final client in ['WEB', 'ANDROID']) {
          sendLog('[IsolateJS] Buscando match para "$query" con cliente $client...');
          final candidates = await _trySearchWithClient(
            query: query,
            client: client,
            jsRuntime: jsRuntime,
            sendLog: sendLog,
          );
          if (candidates != null && candidates.isNotEmpty) {
            final best = YtSearchMatcher.pickBest(
              candidates,
              artist: request.trackArtist ?? '',
              title: request.trackTitle ?? '',
              durationSec: request.durationSeconds,
            );
            if (best != null) {
              sendLog('[IsolateJS] Match seleccionado: ${best.videoId} (score ${best.score}) para "$query"');
              _resolvedMatchCache[videoId] = best.videoId;
              final resolvedRequest = ExtractionRequest(
                videoId: best.videoId,
                requestId: request.requestId,
                priority: request.priority,
                trackTitle: request.trackTitle,
                trackArtist: request.trackArtist,
                durationSeconds: request.durationSeconds,
              );
              return _processExtraction(
                request: resolvedRequest,
                jsRuntime: jsRuntime,
                retryPolicy: retryPolicy,
                sendLog: sendLog,
              );
            }
            sendLog('[IsolateJS] Ningún candidato superó el umbral de scoring con $client.');
          } else {
            sendLog('[IsolateJS] Búsqueda sin candidatos con $client.');
          }
        }
      }

      sendLog('[IsolateJS] Pista no-YouTube "$videoId" sin coincidencia válida -> notFound');
      return ExtractionFailure(
        requestId: request.requestId,
        error: ExtractionError.notFound,
      );
    }

    final clients = ['ANDROID', 'ANDROID_VR', 'WEB'];
    String lastJsError = '';

    for (final client in clients) {
      sendLog('[IsolateJS] Probando cliente Innertube: $client para videoId: ${request.videoId}...');
      try {
        final evalResult = await _tryExtractWithClient(
          videoId: request.videoId,
          client: client,
          jsRuntime: jsRuntime,
          sendLog: sendLog,
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
    );
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

  static Future<Map<String, dynamic>?> _tryExtractWithClient({
    required String videoId,
    required String client,
    required JavascriptRuntime? jsRuntime,
    required void Function(String) sendLog,
  }) async {
    if (jsRuntime == null) return null;

    final jsRequestId = 'js_${DateTime.now().microsecondsSinceEpoch}_${videoId}_$client';
    final completer = Completer<Map<String, dynamic>>();
    _jsExtractCompleters[jsRequestId] = completer;

    final code = "globalThis.extractVideo('$videoId', '$client', '$jsRequestId');";
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

  static Future<List<Map<String, dynamic>>?> _trySearchWithClient({
    required String query,
    required String client,
    required JavascriptRuntime? jsRuntime,
    required void Function(String) sendLog,
  }) async {
    if (jsRuntime == null) return null;

    final jsRequestId = 'js_search_${DateTime.now().microsecondsSinceEpoch}_$client';
    final completer = Completer<Map<String, dynamic>>();
    _jsSearchCompleters[jsRequestId] = completer;

    final safeQuery = query.replaceAll("'", "\\'");
    final code = "globalThis.searchVideos('$safeQuery', '$client', '$jsRequestId');";
    final evalRes = jsRuntime.evaluate(code);

    if (evalRes.isError) {
      sendLog('[IsolateJS ERROR AL EJECUTAR SEARCHVIDEOS] ${evalRes.stringResult}');
      _jsSearchCompleters.remove(jsRequestId);
      return null;
    }

    jsRuntime.executePendingJob();

    try {
      final res = await completer.future.timeout(const Duration(seconds: 20));
      if (res.containsKey('results') && res['results'] is List) {
        return (res['results'] as List).cast<Map<String, dynamic>>();
      }
      if (res.containsKey('error')) {
        sendLog('[IsolateJS] searchVideos $client devolvió error: ${res['error']}');
      }
      return null;
    } catch (e) {
      _jsSearchCompleters.remove(jsRequestId);
      sendLog('[IsolateJS] Timeout en searchVideos para $client');
      return null;
    }
  }
}
