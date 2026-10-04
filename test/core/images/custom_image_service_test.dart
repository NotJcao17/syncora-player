import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncora_player/core/images/custom_image_service.dart';
import 'package:syncora_player/core/utils/local_image_path.dart';

Uint8List _jpegWithExif(int width, int height) {
  final src = img.Image(width: width, height: height)..clear(img.ColorRgb8(200, 30, 30));
  src.exif.imageIfd['Make'] = img.IfdValueAscii('CamaraDePrueba');
  src.exif.gpsIfd['GPSLatitudeRef'] = img.IfdValueAscii('N');
  return img.encodeJpg(src);
}

void main() {
  group('processImage', () {
    test('recorta al centro, reduce al tamaño pedido y quita el EXIF', () {
      final source = _jpegWithExif(1200, 800);
      expect(img.decodeJpg(source)!.exif.isEmpty, isFalse, reason: 'la fuente sí lleva EXIF');

      final out = CustomImageService.processImage(source, 640);
      final decoded = img.decodeJpg(out)!;

      expect(decoded.width, 640);
      expect(decoded.height, 640);
      expect(decoded.exif.isEmpty, isTrue);
    });

    test('no amplía imágenes más pequeñas que el tamaño final', () {
      final out = CustomImageService.processImage(_jpegWithExif(300, 500), 640);
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 300);
      expect(decoded.height, 300);
    });

    test('un PNG con transparencia sale como JPEG opaco', () {
      final png = img.encodePng(img.Image(width: 100, height: 100, numChannels: 4));
      final out = CustomImageService.processImage(png, 320);
      expect(out.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    });

    test('bytes que no son imagen dan un error legible', () {
      expect(
        () => CustomImageService.processImage(Uint8List.fromList([1, 2, 3, 4]), 640),
        throwsA(isA<CustomImageException>()),
      );
    });
  });

  group('prepare (códec del motor)', () {
    testWidgets('recorta al centro, reduce y sale sin EXIF', (tester) async {
      final out = await tester.runAsync(
        () => CustomImageService().prepare(_jpegWithExif(1200, 800), CustomImageKind.playlistCover),
      );
      final decoded = img.decodeJpg(out!)!;
      expect(decoded.width, 640);
      expect(decoded.height, 640);
      expect(decoded.exif.isEmpty, isTrue);
      final p = decoded.getPixel(320, 320);
      expect(p.r, greaterThan(150));
      expect(p.g, lessThan(80));
    });

    testWidgets('aplica la orientación del EXIF de las fotos de móvil', (tester) async {
      // 400x200 apaisada: izquierda roja, derecha azul. Orientación 6 = girar
      // 90° a la derecha al mostrarla: la mitad roja queda arriba.
      final src = img.Image(width: 400, height: 200);
      img.fillRect(src, x1: 0, y1: 0, x2: 199, y2: 199, color: img.ColorRgb8(220, 0, 0));
      img.fillRect(src, x1: 200, y1: 0, x2: 399, y2: 199, color: img.ColorRgb8(0, 0, 220));
      src.exif.imageIfd.orientation = 6;
      final out = await tester.runAsync(
        () => CustomImageService().prepare(img.encodeJpg(src), CustomImageKind.avatar),
      );
      final decoded = img.decodeJpg(out!)!;
      expect(decoded.width, 200);
      final top = decoded.getPixel(100, 10);
      final bottom = decoded.getPixel(100, 190);
      expect(top.r, greaterThan(150), reason: 'arriba debe quedar la mitad roja');
      expect(bottom.b, greaterThan(150), reason: 'abajo debe quedar la mitad azul');
    });
  });

  group('upload', () {
    test('manda la acción y el id de la playlist en la query', () async {
      Map<String, dynamic>? sentQuery;
      final service = CustomImageService(invoke: (name, {body, queryParameters}) async {
        sentQuery = queryParameters;
        throw FunctionException(status: 409, details: {'error': 'quota_exceeded', 'message': 'Llegaste al máximo'});
      });

      await expectLater(
        service.upload(Uint8List(4), CustomImageKind.playlistCover, playlistRemoteId: 'abc'),
        throwsA(isA<CustomImageException>().having((e) => e.message, 'message', 'Llegaste al máximo')),
      );
      expect(sentQuery, {'action': 'upload', 'kind': 'playlist', 'playlist_id': 'abc'});
    });

    test('un fallo de red se traduce a un mensaje para el usuario', () async {
      final service = CustomImageService(invoke: (name, {body, queryParameters}) async {
        throw Exception('socket');
      });
      await expectLater(
        service.upload(Uint8List(4), CustomImageKind.avatar),
        throwsA(isA<CustomImageException>()),
      );
    });
  });

  test('isLocalImagePath distingue rutas de URLs, degradados y colores', () {
    expect(isLocalImagePath('/data/user/0/app/files/a.jpg'), isTrue);
    expect(isLocalImagePath(r'C:\Users\x\Documents\syncora\custom_images\a.jpg'), isTrue);
    expect(isLocalImagePath('C:/Users/x/a.jpg'), isTrue);
    expect(isLocalImagePath('file:///C:/Users/x/a.jpg'), isTrue);
    expect(isLocalImagePath('https://pub-abc.r2.dev/u/x/a/1.jpg'), isFalse);
    expect(isLocalImagePath('gradient:3'), isFalse);
    expect(isLocalImagePath('color:#1db954'), isFalse);
    expect(isLocalImagePath(''), isFalse);
  });
}
