import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncora_player/data/services/ai_assistant_service.dart';
import 'package:syncora_player/data/services/ai_key_storage.dart';

/// Doble de prueba en memoria de [AiKeyStorage] -- evita tocar
/// `flutter_secure_storage` real (backed por keychain/keystore de la
/// plataforma, no disponible en `flutter test`).
class FakeAiKeyStorage implements AiKeyStorage {
  String? _key;

  FakeAiKeyStorage({String? initialKey}) : _key = initialKey;

  @override
  Future<String?> getKey() async => _key;

  @override
  Future<void> setKey(String key) async => _key = key;

  @override
  Future<void> deleteKey() async => _key = null;
}

void main() {
  group('AiAssistantService', () {
    group('header X-User-AI-Key (7.E.9: flujo BYOK)', () {
      test('se adjunta cuando hay una llave BYOK guardada', () async {
        Map<String, String>? capturedHeaders;
        final service = AiAssistantService(
          keyStorage: FakeAiKeyStorage(initialKey: 'my-secret-gemini-key'),
          invoke: (functionName, {headers = const {}, body}) async {
            capturedHeaders = headers;
            return const FunctionResponse(
              status: 200,
              data: {
                'action': 'lyric_search',
                'result': {'songs': <Map<String, dynamic>>[]},
              },
            );
          },
        );

        await service.lyricSearch(lyricFragment: 'y en tu cintura un sol');

        expect(capturedHeaders, isNotNull);
        expect(capturedHeaders!['X-User-AI-Key'], equals('my-secret-gemini-key'));
      });

      test('NO se adjunta cuando no hay llave BYOK guardada', () async {
        Map<String, String>? capturedHeaders;
        final service = AiAssistantService(
          keyStorage: FakeAiKeyStorage(),
          invoke: (functionName, {headers = const {}, body}) async {
            capturedHeaders = headers;
            return const FunctionResponse(
              status: 200,
              data: {
                'action': 'lyric_search',
                'result': {'songs': <Map<String, dynamic>>[]},
              },
            );
          },
        );

        await service.lyricSearch(lyricFragment: 'fragmento');

        expect(capturedHeaders, isNotNull);
        expect(capturedHeaders!.containsKey('X-User-AI-Key'), isFalse);
      });

      test('deja de adjuntarse tras borrar la llave (deleteKey)', () async {
        final storage = FakeAiKeyStorage(initialKey: 'a-key');
        Map<String, String>? capturedHeaders;
        final service = AiAssistantService(
          keyStorage: storage,
          invoke: (functionName, {headers = const {}, body}) async {
            capturedHeaders = headers;
            return const FunctionResponse(status: 200, data: {'action': 'lyric_search', 'result': {'songs': <Map<String, dynamic>>[]}});
          },
        );

        await storage.deleteKey();
        await service.lyricSearch(lyricFragment: 'fragmento');

        expect(capturedHeaders!.containsKey('X-User-AI-Key'), isFalse);
      });
    });

    group('body de la petición', () {
      test('incluye el action correcto y el payload de la acción', () async {
        Object? capturedBody;
        final service = AiAssistantService(
          keyStorage: FakeAiKeyStorage(),
          invoke: (functionName, {headers = const {}, body}) async {
            capturedBody = body;
            return const FunctionResponse(status: 200, data: {'action': 'create_playlist', 'result': {'tracks': <Map<String, dynamic>>[]}});
          },
        );

        await service.createPlaylist(prompt: 'música para estudiar', count: 25);

        expect(capturedBody, isA<Map<String, dynamic>>());
        final body = capturedBody as Map<String, dynamic>;
        expect(body['action'], equals('create_playlist'));
        expect(body['prompt'], equals('música para estudiar'));
        expect(body['count'], equals(25));
      });

      test('modifyPlaylistRemove manda contextTracks con ids', () async {
        Object? capturedBody;
        final service = AiAssistantService(
          keyStorage: FakeAiKeyStorage(),
          invoke: (functionName, {headers = const {}, body}) async {
            capturedBody = body;
            return const FunctionResponse(status: 200, data: {'action': 'modify_playlist_remove', 'result': {'idsToRemove': <String>[]}});
          },
        );

        await service.modifyPlaylistRemove(
          prompt: 'quita las de rock',
          contextTracks: [
            {'id': '1', 'title': 'A', 'artist': 'B'},
          ],
        );

        final body = capturedBody as Map<String, dynamic>;
        expect(body['action'], equals('modify_playlist_remove'));
        expect(body['contextTracks'], isA<List>());
      });
    });

    group('respuesta exitosa', () {
      test('devuelve el campo "result" ya decodificado', () async {
        final service = AiAssistantService(
          keyStorage: FakeAiKeyStorage(),
          invoke: (functionName, {headers = const {}, body}) async {
            return const FunctionResponse(
              status: 200,
              data: {
                'action': 'create_queue',
                'result': {
                  'tracks': [
                    {'title': 'Song A', 'artist': 'Artist A'},
                  ],
                },
              },
            );
          },
        );

        final result = await service.createQueue(prompt: 'algo animado');

        expect(result['tracks'], isA<List>());
        expect((result['tracks'] as List).first['title'], equals('Song A'));
      });
    });

    group('7.E.3b: distinción de códigos de error', () {
      test('rate_limited_user se distingue de shared_quota_exhausted', () async {
        final service = AiAssistantService(
          keyStorage: FakeAiKeyStorage(),
          invoke: (functionName, {headers = const {}, body}) async {
            throw const FunctionsHttpException(
              status: 429,
              details: {'error': 'rate_limited_user', 'message': 'Espera un momento e intenta de nuevo.'},
            );
          },
        );

        try {
          await service.lyricSearch(lyricFragment: 'x');
          fail('debía lanzar AiAssistantException');
        } on AiAssistantException catch (e) {
          expect(e.code, equals(AiErrorCode.rateLimitedUser));
          expect(e.message, contains('Espera un momento'));
        }
      });

      test('shared_quota_exhausted trae el código correcto y el mensaje del servidor', () async {
        const serverMessage =
            'La IA gratuita de la app se agotó por hoy — ingresa tu propia API key gratuita de Gemini para '
            'seguir usando esta función.';
        final service = AiAssistantService(
          keyStorage: FakeAiKeyStorage(),
          invoke: (functionName, {headers = const {}, body}) async {
            throw const FunctionsHttpException(
              status: 429,
              details: {'error': 'shared_quota_exhausted', 'message': serverMessage},
            );
          },
        );

        try {
          await service.lyricSearch(lyricFragment: 'x');
          fail('debía lanzar AiAssistantException');
        } on AiAssistantException catch (e) {
          expect(e.code, equals(AiErrorCode.sharedQuotaExhausted));
          expect(e.message, equals(serverMessage));
        }
      });

      test('ambos códigos son valores de enum distintos aunque el servidor use el mismo HTTP 429', () {
        expect(AiErrorCode.rateLimitedUser, isNot(equals(AiErrorCode.sharedQuotaExhausted)));
      });

      test('un código desconocido cae en AiErrorCode.unknown en vez de lanzar', () async {
        final service = AiAssistantService(
          keyStorage: FakeAiKeyStorage(),
          invoke: (functionName, {headers = const {}, body}) async {
            throw const FunctionsHttpException(status: 418, details: {'error': 'algo_no_documentado'});
          },
        );

        try {
          await service.lyricSearch(lyricFragment: 'x');
          fail('debía lanzar AiAssistantException');
        } on AiAssistantException catch (e) {
          expect(e.code, equals(AiErrorCode.unknown));
        }
      });

      test('un fallo de red (sin FunctionException) se mapea a unknown con mensaje genérico', () async {
        final service = AiAssistantService(
          keyStorage: FakeAiKeyStorage(),
          invoke: (functionName, {headers = const {}, body}) async {
            throw Exception('socket closed');
          },
        );

        try {
          await service.lyricSearch(lyricFragment: 'x');
          fail('debía lanzar AiAssistantException');
        } on AiAssistantException catch (e) {
          expect(e.code, equals(AiErrorCode.unknown));
          expect(e.message, isNotEmpty);
        }
      });
    });
  });
}
