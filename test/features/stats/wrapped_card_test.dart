import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/stats/screens/wrapped_screen.dart';

/// Las tarjetas del Wrapped tienen relacion fija 9:16 y contenido denso (la
/// de resumen lleva collage, cifra grande, tres fichas y una banda). Un
/// desbordamiento no rompe la app pero sale en la imagen exportada, asi que
/// conviene fijarlo: se pintan a varios anchos y no debe saltar ningun
/// overflow.
///
/// Las imagenes van vacias a proposito: `_FramedImage` reserva el mismo
/// tamano con el marcador de posicion, asi que la geometria es la misma sin
/// depender de la red.
void main() {
  const urlsVacias = ['', '', ''];

  final resumen = WrappedCardData(
    eyebrow: 'Tu resumen · 12 meses',
    colors: const [Color(0xFF6D28D9), Color(0xFF2563EB)],
    layout: WrappedLayout.summary,
    collage: urlsVacias,
    artists: const [WrappedItem(title: 'Un Artista Con Nombre Bastante Largo')],
    tracks: const [
      WrappedItem(
        title: 'Una Cancion Con Un Titulo Absurdamente Largo (Version Extendida)',
        subtitle: 'Artista',
      ),
    ],
    totalTime: '1234 h 56 min',
    topGenre: 'Electronica Experimental',
    facts: const [
      (label: 'Artistas', value: '9999'),
      (label: 'Canciones', value: '9999'),
      (label: 'Reproducciones', value: '99999'),
    ],
  );

  final artistas = WrappedCardData(
    eyebrow: 'Tus artistas · 12 meses',
    colors: const [Color(0xFF0EA5E9), Color(0xFF1E3A8A)],
    layout: WrappedLayout.artistShowcase,
    artists: const [
      WrappedItem(title: 'Nombre Larguisimo De Artista Numero Uno'),
      WrappedItem(title: 'Segundo Artista Con Nombre Largo'),
      WrappedItem(title: 'Tercero'),
      WrappedItem(title: 'Cuarto Artista'),
      WrappedItem(title: 'Quinto'),
    ],
  );

  final canciones = WrappedCardData(
    eyebrow: 'Tus canciones · 12 meses',
    colors: const [Color(0xFFDB2777), Color(0xFF6D28D9)],
    layout: WrappedLayout.trackShowcase,
    tracks: const [
      WrappedItem(title: 'Cancion Numero Uno Con Titulo Muy Largo', subtitle: 'Artista'),
      WrappedItem(title: 'Segunda Cancion'),
      WrappedItem(title: 'Tercera'),
      WrappedItem(title: 'Cuarta Cancion Larga'),
      WrappedItem(title: 'Quinta'),
    ],
  );

  Future<void> pintar(WidgetTester tester, WrappedCardData data, double ancho) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: ancho,
              height: ancho * 16 / 9,
              child: WrappedCard(data: data),
            ),
          ),
        ),
      ),
    );
  }

  // 260: tarjeta en un movil estrecho. 500: la que se ve en escritorio.
  for (final ancho in [260.0, 320.0, 420.0, 500.0]) {
    testWidgets('el resumen cabe a ${ancho.toInt()} px', (tester) async {
      await pintar(tester, resumen, ancho);
      expect(tester.takeException(), isNull);
    });

    testWidgets('la tarjeta de artistas cabe a ${ancho.toInt()} px', (tester) async {
      await pintar(tester, artistas, ancho);
      expect(tester.takeException(), isNull);
    });

    testWidgets('la tarjeta de canciones cabe a ${ancho.toInt()} px', (tester) async {
      await pintar(tester, canciones, ancho);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('el resumen aguanta sin genero y sin tops', (tester) async {
    await pintar(
      tester,
      WrappedCardData(
        eyebrow: 'Tu resumen · 7 días',
        colors: const [Color(0xFF6D28D9), Color(0xFF2563EB)],
        layout: WrappedLayout.summary,
        totalTime: '3 min',
        facts: const [(label: 'Artistas', value: '1')],
      ),
      320,
    );
    expect(tester.takeException(), isNull);
  });
}
