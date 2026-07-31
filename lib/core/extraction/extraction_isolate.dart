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

/// Isolate de extracción que vive durante toda la sesión de la app.
/// Ejecuta QuickJS (flutter_js) en background sin congelar la UI (Pitfall #8).
class ExtractionIsolate {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  final Map<String, Completer<ExtractionResult>> _pendingRequests = {};
  ReceivePort? _mainReceivePort;

  bool get isInitialized => _isolateSendPort != null;

  Future<void> spawn() async {
    if (isInitialized) return;

    final token = RootIsolateToken.instance;
    if (token == null) {
      throw StateError('RootIsolateToken no está disponible.');
    }

    final jsBundle = await JsBundleLoader.loadCompleteBundle();
    _mainReceivePort = ReceivePort();

    _isolate = await Isolate.spawn(
      _isolateEntryPoint,
      _IsolateInitMessage(
        token: token,
        mainSendPort: _mainReceivePort!.sendPort,
        jsBundle: jsBundle,
      ),
    );

    _mainReceivePort!.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
      } else if (message is ExtractionResult) {
        final completer = _pendingRequests.remove(message.requestId);
        completer?.complete(message);
      }
    });
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

  void dispose() {
    _mainReceivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
  }

  /// Punto de entrada del Isolate secundario
  static void _isolateEntryPoint(_IsolateInitMessage initMessage) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(initMessage.token);

    final childReceivePort = ReceivePort();
    initMessage.mainSendPort.send(childReceivePort.sendPort);

    final fetchBridge = DartFetchBridge();
    final retryPolicy = RetryPolicy();

    JavascriptRuntime? jsRuntime;

    try {
      jsRuntime = getJavascriptRuntime();

      // Canal consoleLog
      jsRuntime.onMessage('consoleLog', (dynamic args) {
        try {
          final data = jsonDecode(args.toString());
          dev.log('[IsolateJS:${data['type']}] ${data['message']}');
        } catch (_) {
          dev.log('[IsolateJS] $args');
        }
      });

      // Canal setTimeout
      jsRuntime.onMessage('setTimeout', (dynamic args) {
        try {
          final data = jsonDecode(args.toString());
          final int id = data['id'];
          final int delay = data['delay'] ?? 0;
          Future.delayed(Duration(milliseconds: delay), () {
            jsRuntime?.evaluate('globalThis.__fireTimeout($id);');
          });
        } catch (e) {
          dev.log('[IsolateJS] Error en setTimeout: $e');
        }
      });

      // Canal dartFetch
      jsRuntime.onMessage('dartFetch', (dynamic args) async {
        try {
          final data = jsonDecode(args.toString());
          final int id = data['id'];
          final String url = data['url'];
          final String method = data['method'] ?? 'GET';
          final Map<String, dynamic>? headers = data['headers'] != null
              ? Map<String, dynamic>.from(data['headers'])
              : null;
          final dynamic body = data['body'];

          final res = await fetchBridge.fetch(
            url: url,
            method: method,
            headers: headers,
            body: body,
          );

          final headersJson = jsonEncode(res.headers);
          final escapedBody = jsonEncode(res.bodyText);

          final script =
              'globalThis.__dartFetchResponse($id, ${res.statusCode}, ${jsonEncode(res.statusText)}, $headersJson, $escapedBody, null);';
          jsRuntime?.evaluate(script);
        } catch (err) {
          try {
            final data = jsonDecode(args.toString());
            final int id = data['id'];
            final script =
                'globalThis.__dartFetchResponse($id, 500, "Error", "{}", "", ${jsonEncode(err.toString())});';
            jsRuntime?.evaluate(script);
          } catch (_) {}
        }
      });

      // Evaluar bundle de polyfills + youtubei.js
      jsRuntime.evaluate(initMessage.jsBundle);
    } catch (e) {
      dev.log('[IsolateJS] Error al inicializar QuickJS: $e');
    }

    // Escuchar peticiones enviadas desde el Main Isolate
    await for (final message in childReceivePort) {
      if (message is ExtractionRequest) {
        final result = await _processExtraction(
          request: message,
          jsRuntime: jsRuntime,
          retryPolicy: retryPolicy,
          fetchBridge: fetchBridge,
        );
        initMessage.mainSendPort.send(result);
      }
    }
  }

  /// Intenta extracción probando clientes exentos de PoToken en orden (Pitfall #18)
  static Future<ExtractionResult> _processExtraction({
    required ExtractionRequest request,
    required JavascriptRuntime? jsRuntime,
    required RetryPolicy retryPolicy,
    required DartFetchBridge fetchBridge,
  }) async {
    final clients = ['tv', 'tv_downgraded', 'android_vr'];

    for (final client in clients) {
      try {
        final evalResult = await _tryExtractWithClient(
          videoId: request.videoId,
          client: client,
          jsRuntime: jsRuntime,
        );

        if (evalResult != null && evalResult['url'] != null) {
          retryPolicy.reset(request.videoId);
          return ExtractionSuccess(
            requestId: request.requestId,
            streamUrl: evalResult['url'] as String,
            headers: Map<String, String>.from(evalResult['headers'] ?? {}),
          );
        }
      } catch (e) {
        dev.log('[IsolateJS] Fallo de cliente $client para ${request.videoId}: $e');
      }
    }

    // Fallback o reintento ante 403 / error de red
    const errorType = ExtractionError.rateLimited;

    if (retryPolicy.canRetry(request.videoId, errorType)) {
      await Future.delayed(const Duration(seconds: 2));
      return _processExtraction(
        request: request,
        jsRuntime: jsRuntime,
        retryPolicy: retryPolicy,
        fetchBridge: fetchBridge,
      );
    }

    return ExtractionFailure(
      requestId: request.requestId,
      error: errorType,
      message: 'No se pudo extraer la URL con clientes exentos de PoToken ($clients).',
    );
  }

  static Future<Map<String, dynamic>?> _tryExtractWithClient({
    required String videoId,
    required String client,
    required JavascriptRuntime? jsRuntime,
  }) async {
    if (jsRuntime == null) return null;

    final code = '''
    (async function() {
      if (typeof Innertube !== 'undefined') {
        try {
          const yt = await Innertube.create({ client_type: '$client' });
          const info = await yt.getBasicInfo('$videoId');
          const format = info.chooseFormat({ quality: 'best', type: 'audio' });
          const url = format.decipher(yt.session.player);
          return JSON.stringify({
            url: url,
            headers: {
              'User-Agent': (yt.session && yt.session.player && yt.session.player.userAgent) || 'Mozilla/5.0',
              'Referer': 'https://www.youtube.com/'
            }
          });
        } catch(e) {
          return JSON.stringify({ error: e.message });
        }
      } else {
        return JSON.stringify({ error: 'Innertube bundle not loaded' });
      }
    })()
    ''';

    final jsRes = jsRuntime.evaluate(code);
    final String stringResult = jsRes.stringResult;

    if (stringResult.isNotEmpty && stringResult != 'null' && stringResult != 'undefined') {
      try {
        final map = jsonDecode(stringResult);
        if (map is Map<String, dynamic> && map.containsKey('url')) {
          return map;
        }
      } catch (_) {}
    }
    return null;
  }
}
