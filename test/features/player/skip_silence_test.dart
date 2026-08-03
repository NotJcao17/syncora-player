import 'package:flutter_test/flutter_test.dart';

/// Test unitario de la lógica de detección y recorte de silencio (Skip Silence).
///
/// Simula los logs emitidos por libmpv (`silencedetect`) en Windows
/// para verificar que:
/// 1. `silence_end: 0.42` produce un seek a 420ms (primer sample de audio real).
/// 2. El seek se ejecuta una sola vez por pista (no en bucle).
/// 3. Al cambiar de pista se resetea la bandera para capturar el intro de la nueva.

class SkipSilenceLogParser {
  bool skipSilence = false;
  bool seekedThisTrack = false;
  Duration? lastSeekPosition;
  int seekCount = 0;

  static final RegExp silenceEndRe = RegExp(r'silence_end:\s*([\d.]+)');

  void onTrackLoaded() {
    seekedThisTrack = false;
  }

  void processLog({required String prefix, required String text}) {
    if (!skipSilence) return;
    if (prefix != 'silencedetect') return;
    if (seekedThisTrack) return;

    final match = silenceEndRe.firstMatch(text);
    if (match != null) {
      final seconds = double.tryParse(match.group(1) ?? '');
      if (seconds != null && seconds > 0.1) {
        seekedThisTrack = true;
        seekCount++;
        lastSeekPosition = Duration(milliseconds: (seconds * 1000).round());
      }
    }
  }
}

void main() {
  group('Skip Silence mpv log parsing tests', () {
    late SkipSilenceLogParser parser;

    setUp(() {
      parser = SkipSilenceLogParser();
    });

    test('1. Evento silence_end: 0.42 produce seek exacto a 420ms', () {
      parser.skipSilence = true;
      parser.processLog(
        prefix: 'silencedetect',
        text: 'silence_end: 0.42 | silence_duration: 0.42',
      );

      expect(parser.seekedThisTrack, isTrue);
      expect(parser.seekCount, equals(1));
      expect(parser.lastSeekPosition, equals(const Duration(milliseconds: 420)));
    });

    test('2. Eventos posteriores de silence_end en la misma pista son ignorados', () {
      parser.skipSilence = true;
      parser.processLog(
        prefix: 'silencedetect',
        text: 'silence_end: 0.42',
      );
      parser.processLog(
        prefix: 'silencedetect',
        text: 'silence_end: 12.50',
      );

      expect(parser.seekCount, equals(1));
      expect(parser.lastSeekPosition, equals(const Duration(milliseconds: 420)));
    });

    test('3. Si skipSilence está desactivado, ignora los eventos', () {
      parser.skipSilence = false;
      parser.processLog(
        prefix: 'silencedetect',
        text: 'silence_end: 0.42',
      );

      expect(parser.seekedThisTrack, isFalse);
      expect(parser.seekCount, equals(0));
      expect(parser.lastSeekPosition, isNull);
    });

    test('4. Al cargar nueva pista, se permite detectar el nuevo intro', () {
      parser.skipSilence = true;
      parser.processLog(
        prefix: 'silencedetect',
        text: 'silence_end: 0.42',
      );
      expect(parser.seekCount, equals(1));

      // Nueva pista cargada
      parser.onTrackLoaded();
      expect(parser.seekedThisTrack, isFalse);

      // Segundo intro detectado
      parser.processLog(
        prefix: 'silencedetect',
        text: 'silence_end: 0.85',
      );
      expect(parser.seekCount, equals(2));
      expect(parser.lastSeekPosition, equals(const Duration(milliseconds: 850)));
    });
  });
}
