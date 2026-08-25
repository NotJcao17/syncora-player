import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/widgets/error_state.dart';

void main() {
  group('ErrorStateWidget.formatErrorMessage', () {
    test('Formats network and connectivity exceptions into friendly messages', () {
      const socketError = SocketException('Failed host lookup: api.deezer.com');
      expect(
        ErrorStateWidget.formatErrorMessage(socketError),
        'No se pudo conectar con el servidor. Revisa tu conexión a internet.',
      );

      expect(
        ErrorStateWidget.formatErrorMessage('ClientException with SocketException: Connection refused'),
        'No se pudo conectar con el servidor. Revisa tu conexión a internet.',
      );

      expect(
        ErrorStateWidget.formatErrorMessage('Connection timeout while fetching stream'),
        'No se pudo conectar con el servidor. Revisa tu conexión a internet.',
      );
    });

    test('Formats 404 / Not Found errors friendly', () {
      expect(
        ErrorStateWidget.formatErrorMessage('Error 404: not found'),
        'No se encontró el contenido solicitado o no está disponible.',
      );
    });

    test('Formats 403 / Forbidden / 401 errors friendly', () {
      expect(
        ErrorStateWidget.formatErrorMessage('Http 403: Forbidden stream access'),
        'Esta canción o contenido no está disponible en este momento.',
      );
    });

    test('Formats 429 / Rate Limit errors friendly', () {
      expect(
        ErrorStateWidget.formatErrorMessage('Rate limit exceeded (HTTP 429)'),
        'Demasiadas solicitudes. Por favor, espera un momento e intenta nuevamente.',
      );
    });

    test('Cleans Exception: and AuthException: prefixes', () {
      expect(
        ErrorStateWidget.formatErrorMessage('Exception: Credenciales inválidas'),
        'Credenciales inválidas',
      );

      expect(
        ErrorStateWidget.formatErrorMessage('AuthException: Correo o contraseña incorrectos'),
        'Correo o contraseña incorrectos',
      );
    });

    test('Hides raw stack traces and JSON dumps with default fallback', () {
      expect(
        ErrorStateWidget.formatErrorMessage('#0   syncora_audio_engine.dart:124\n#1   main.dart:50'),
        'Ocurrió un problema temporal. Intenta nuevamente.',
      );

      expect(
        ErrorStateWidget.formatErrorMessage('{"error": {"code": 500, "details": "internal"}}'),
        'Ocurrió un problema temporal. Intenta nuevamente.',
      );
    });

    test('Handles null and empty inputs safely', () {
      expect(
        ErrorStateWidget.formatErrorMessage(null),
        'Ocurrió un problema temporal. Intenta nuevamente.',
      );

      expect(
        ErrorStateWidget.formatErrorMessage('   '),
        'Ocurrió un problema temporal. Intenta nuevamente.',
      );
    });
  });
}
