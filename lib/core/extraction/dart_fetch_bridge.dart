import 'package:dio/dio.dart';

class DartFetchResponse {
  final int statusCode;
  final String statusText;
  final Map<String, String> headers;
  final String bodyText;

  DartFetchResponse({
    required this.statusCode,
    required this.statusText,
    required this.headers,
    required this.bodyText,
  });

  Map<String, dynamic> toJson() => {
        'status': statusCode,
        'statusText': statusText,
        'headers': headers,
        'body': bodyText,
      };
}

/// Puente de red Dart que reemplaza fetch de JS en QuickJS.
/// Sigue redirecciones (hasta 5 niveles), maneja cookies/sesión persistente,
/// decodifica gzip/brotli y preserva los mismos headers (Pitfall #13).
class DartFetchBridge {
  late final Dio _dio;
  final Map<String, String> _cookies = {};

  DartFetchBridge({Dio? customDio}) {
    _dio = customDio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
            followRedirects: true,
            maxRedirects: 5,
            validateStatus: (status) => status != null && status < 600,
            responseType: ResponseType.plain,
          ),
        );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (_cookies.isNotEmpty) {
            final cookieHeader =
                _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
            options.headers['cookie'] = cookieHeader;
          }
          return handler.next(options);
        },
        onResponse: (response, handler) {
          final setCookieHeaders = response.headers['set-cookie'];
          if (setCookieHeaders != null) {
            for (final header in setCookieHeaders) {
              final parts = header.split(';')[0].split('=');
              if (parts.length >= 2) {
                _cookies[parts[0].trim()] = parts.sublist(1).join('=').trim();
              }
            }
          }
          return handler.next(response);
        },
      ),
    );
  }

  Future<DartFetchResponse> fetch({
    required String url,
    String method = 'GET',
    Map<String, dynamic>? headers,
    dynamic body,
  }) async {
    try {
      final reqHeaders = <String, dynamic>{};
      if (headers != null) {
        headers.forEach((key, value) {
          reqHeaders[key.toLowerCase()] = value.toString();
        });
      }

      final response = await _dio.request<String>(
        url,
        data: body,
        options: Options(
          method: method.toUpperCase(),
          headers: reqHeaders,
          responseType: ResponseType.plain,
        ),
      );

      final resHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        resHeaders[name.toLowerCase()] = values.join(', ');
      });

      return DartFetchResponse(
        statusCode: response.statusCode ?? 200,
        statusText: response.statusMessage ?? 'OK',
        headers: resHeaders,
        bodyText: response.data ?? '',
      );
    } on DioException catch (e) {
      if (e.response != null) {
        final resHeaders = <String, String>{};
        e.response?.headers.forEach((name, values) {
          resHeaders[name.toLowerCase()] = values.join(', ');
        });

        return DartFetchResponse(
          statusCode: e.response?.statusCode ?? 500,
          statusText: e.response?.statusMessage ?? 'HTTP Error',
          headers: resHeaders,
          bodyText: e.response?.data?.toString() ?? e.message ?? '',
        );
      }
      rethrow;
    }
  }

  void clearSession() {
    _cookies.clear();
  }
}
