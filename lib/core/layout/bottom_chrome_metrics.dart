/// Alturas reales del "chrome" inferior en móvil (mini reproductor + barra de
/// navegación), en un único sitio.
///
/// Ronda 3 (E3). Existían dos juegos de números distintos para lo mismo:
/// `app_shell.dart` posicionaba el aviso de "sin conexión" a `152 / 80`, y
/// `app_toast.dart` ponía sus avisos a `144 / 72`. Esos 8 px de diferencia
/// hacían que el aviso quedara **por debajo** del borde superior del mini
/// reproductor, superpuesto a su esquina redondeada y su sombra — que es lo
/// que se veía como "la notificación de me gusta sale descolocada" según desde
/// dónde se disparara.
///
/// La diferencia además iba a crecer: el mini reproductor de móvil ganó una
/// barra de progreso en esta misma ronda (E1), así que cualquier constante
/// duplicada se habría quedado corta otra vez. Con los valores aquí, tocar el
/// alto del mini reproductor obliga a actualizar un solo sitio.
abstract class BottomChromeMetrics {
  /// Alto del mini reproductor móvil: padding 10 arriba + 8 abajo, contenido
  /// de 48 (la portada, el control más alto de la fila), 8 de separación y
  /// 2 de la barra de progreso.
  static const double miniPlayerHeight = 76;

  /// Alto de la barra de navegación inferior **sin** el inset del sistema:
  /// padding 10 arriba + 10 abajo sobre un destino de ~44.
  static const double navBarHeight = 64;

  /// Separación entre el chrome inferior y lo que flote encima.
  static const double floatingGap = 12;

  /// Distancia desde el borde inferior de la pantalla a la que debe flotar un
  /// elemento (aviso, toast) para quedar justo por encima del chrome.
  ///
  /// [hasMiniPlayer] es "hay una pista activa"; [bottomInset] es el inset del
  /// sistema (barra de gestos), que la barra de navegación absorbe en su
  /// propio padding.
  static double floatingBottomOffset({
    required bool hasMiniPlayer,
    required double bottomInset,
  }) {
    final chrome = navBarHeight + (hasMiniPlayer ? miniPlayerHeight : 0);
    return chrome + floatingGap + bottomInset;
  }
}
