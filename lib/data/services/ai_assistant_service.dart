import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ai_key_storage.dart';

/// Fase 7.E.4 -- las 5 acciones que soporta la Edge Function `ai-assistant`
/// (ver `supabase/functions/ai-assistant/actions.ts`, debe mantenerse en
/// sincronía manual con esa lista -- no hay generación de código compartida
/// entre Deno y Dart en este proyecto).
enum AiAction {
  createPlaylist('create_playlist'),
  createQueue('create_queue'),
  modifyPlaylistRemove('modify_playlist_remove'),
  modifyPlaylistAdd('modify_playlist_add'),
  lyricSearch('lyric_search');

  final String value;
  const AiAction(this.value);
}

/// Fase 7.E.3b/7.E.7 -- códigos de error diferenciados que la Edge Function
/// puede devolver (ver `supabase/functions/ai-assistant/errors.ts`, tipo
/// `AiErrorCode`, con el que este enum debe mantenerse alineado). Los dos que
/// la Fase 7.F **debe** distinguir con mensajes propios son
/// [rateLimitedUser] y [sharedQuotaExhausted] -- el resto existen para que
/// ningún error caiga en [unknown] sin necesidad, pero 7.F puede tratarlos
/// de forma genérica si prefiere.
enum AiErrorCode {
  invalidRequest('invalid_request'),
  unauthorized('unauthorized'),
  rateLimitedUser('rate_limited_user'),
  sharedQuotaExhausted('shared_quota_exhausted'),
  byokUpstreamError('byok_upstream_error'),
  upstreamError('upstream_error'),
  invalidAiResponse('invalid_ai_response'),
  serverMisconfigured('server_misconfigured'),
  internalError('internal_error'),
  /// No vino del contrato conocido de la función (red caída, respuesta con
  /// una forma inesperada, etc.) -- siempre existe para que el cliente nunca
  /// se quede sin un valor de enum que asignar.
  unknown('unknown');

  final String wireValue;
  const AiErrorCode(this.wireValue);

  static AiErrorCode fromWireValue(String? value) {
    for (final code in AiErrorCode.values) {
      if (code.wireValue == value) return code;
    }
    return AiErrorCode.unknown;
  }
}

/// Excepción tipada que expone [code] para que 7.F pueda hacer un `switch`
/// exhaustivo sin parsear strings a mano (pedido explícito de 7.E.7).
class AiAssistantException implements Exception {
  final AiErrorCode code;
  final String message;

  const AiAssistantException(this.code, this.message);

  @override
  String toString() => 'AiAssistantException($code, $message)';
}

/// Firma de la llamada de bajo nivel a la Edge Function, inyectable para
/// tests (ver test/data/services/ai_assistant_service_test.dart) sin
/// necesitar un `Supabase.instance` real ni red.
typedef AiFunctionInvoker = Future<FunctionResponse> Function(
  String functionName, {
  Map<String, String> headers,
  Object? body,
});

/// Fase 7.E.7 -- cliente Dart de la Edge Function de IA.
///
/// Responsabilidades: invoca `ai-assistant` con el JWT del usuario (lo
/// adjunta automáticamente `supabase_flutter` mientras haya sesión activa,
/// ver `Supabase.instance.client.functions`), adjunta `X-User-AI-Key` si hay
/// una llave BYOK guardada (7.E.8), y traduce los errores de la función a
/// [AiAssistantException] con un [AiErrorCode] tipado.
class AiAssistantService {
  static const _functionName = 'ai-assistant';

  final AiFunctionInvoker _invoke;
  final AiKeyStorage _keyStorage;

  AiAssistantService({AiFunctionInvoker? invoke, AiKeyStorage? keyStorage})
      : _invoke = invoke ?? _defaultInvoke,
        _keyStorage = keyStorage ?? SecureAiKeyStorage();

  static Future<FunctionResponse> _defaultInvoke(
    String functionName, {
    Map<String, String> headers = const {},
    Object? body,
  }) {
    return Supabase.instance.client.functions.invoke(functionName, headers: headers, body: body);
  }

  /// Llamada genérica: arma el body `{action, ...payload}`, adjunta
  /// `X-User-AI-Key` solo si hay llave BYOK guardada, y devuelve el campo
  /// `result` de la respuesta ya decodificado. Los 5 métodos de abajo son
  /// azúcar tipada sobre este método para el uso de la Fase 7.F.
  Future<Map<String, dynamic>> invoke(AiAction action, Map<String, dynamic> payload) async {
    final headers = <String, String>{};
    final byokKey = await _keyStorage.getKey();
    if (byokKey != null && byokKey.isNotEmpty) {
      headers['X-User-AI-Key'] = byokKey;
    }

    final body = <String, dynamic>{'action': action.value, ...payload};

    final FunctionResponse response;
    try {
      response = await _invoke(_functionName, headers: headers, body: body);
    } on FunctionException catch (e) {
      throw _mapFunctionException(e);
    } catch (e) {
      throw AiAssistantException(
        AiErrorCode.unknown,
        'No se pudo contactar al asistente de IA. Revisa tu conexión e intenta de nuevo.',
      );
    }

    final data = response.data;
    if (data is Map && data['result'] is Map) {
      return Map<String, dynamic>.from(data['result'] as Map);
    }
    // La función siempre responde `{action, result}` en éxito (200) -- si
    // llegó hasta aquí sin esa forma, es una respuesta inesperada, no un
    // error HTTP (esos ya se capturaron arriba como FunctionException).
    throw const AiAssistantException(
      AiErrorCode.unknown,
      'El asistente de IA devolvió una respuesta con un formato inesperado.',
    );
  }

  AiAssistantException _mapFunctionException(FunctionException e) {
    final details = e.details;
    String? errorCode;
    String? message;
    if (details is Map) {
      final errorField = details['error'];
      final messageField = details['message'];
      if (errorField is String) errorCode = errorField;
      if (messageField is String) message = messageField;
    }

    final code = AiErrorCode.fromWireValue(errorCode);
    return AiAssistantException(
      code,
      message ?? 'El asistente de IA no está disponible en este momento. Intenta de nuevo.',
    );
  }

  // --- Azúcar tipada por acción (lista para el uso de la Fase 7.F) ---------

  /// [contextTracks] tiene doble uso en esta acción (Fase 7.F.1), distinguido
  /// por la clave `params['isRefinement']` (ver `prompts.ts#create_playlist`,
  /// que documenta ambos casos):
  ///  - Sin `isRefinement`: la playlist de referencia elegida por el usuario
  ///    ("basado en una playlist mía", D-11) -- inspiración de estilo.
  ///  - Con `params: {'isRefinement': true, ...}`: el borrador actual (tras
  ///    ediciones locales del usuario) que "afinar con IA" pide revisar según
  ///    el ajuste en [prompt].
  Future<Map<String, dynamic>> createPlaylist({
    String? prompt,
    Map<String, dynamic>? params,
    int? count,
    List<Map<String, dynamic>>? contextTracks,
  }) {
    return invoke(AiAction.createPlaylist, {
      if (prompt != null) 'prompt': prompt,
      if (params != null) 'params': params,
      if (count != null) 'count': count,
      if (contextTracks != null) 'contextTracks': contextTracks,
    });
  }

  Future<Map<String, dynamic>> createQueue({
    String? prompt,
    List<Map<String, dynamic>>? contextTracks,
    bool? interleave,
    int? count,
  }) {
    return invoke(AiAction.createQueue, {
      if (prompt != null) 'prompt': prompt,
      if (contextTracks != null) 'contextTracks': contextTracks,
      if (interleave != null) 'interleave': interleave,
      if (count != null) 'count': count,
    });
  }

  /// [contextTracks] debe traer el `id` de cada pista existente (D-7): el
  /// `response_schema` del servidor restringe la salida exclusivamente a
  /// esos ids.
  Future<Map<String, dynamic>> modifyPlaylistRemove({
    required String prompt,
    required List<Map<String, dynamic>> contextTracks,
  }) {
    return invoke(AiAction.modifyPlaylistRemove, {
      'prompt': prompt,
      'contextTracks': contextTracks,
    });
  }

  Future<Map<String, dynamic>> modifyPlaylistAdd({
    String? prompt,
    List<Map<String, dynamic>>? contextTracks,
    int? count,
  }) {
    return invoke(AiAction.modifyPlaylistAdd, {
      if (prompt != null) 'prompt': prompt,
      if (contextTracks != null) 'contextTracks': contextTracks,
      if (count != null) 'count': count,
    });
  }

  Future<Map<String, dynamic>> lyricSearch({required String lyricFragment}) {
    return invoke(AiAction.lyricSearch, {'prompt': lyricFragment});
  }
}

final aiAssistantServiceProvider = Provider<AiAssistantService>((ref) {
  return AiAssistantService(keyStorage: ref.watch(aiKeyStorageProvider));
});
