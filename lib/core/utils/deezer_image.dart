/// Ajusta el tamaño de una imagen del CDN de Deezer.
///
/// Los modelos guardan `cover_medium`, que son 250x250 — suficiente para
/// miniaturas de lista, pero visiblemente pixelado en la portada grande del
/// reproductor (que en un teléfono 3x ocupa ~1080px reales).
///
/// Las URLs del CDN llevan el tamaño en la propia ruta:
/// `.../cover/<hash>/250x250-000000-80-0-0.jpg`, así que se puede pedir otra
/// resolución reescribiéndola, sin llamadas extra a la API.
class DeezerImage {
  /// Devuelve [url] pidiendo [size]x[size]. Si no es una URL del CDN de Deezer
  /// con tamaño reconocible, la devuelve intacta.
  static String atSize(String url, int size) {
    if (url.isEmpty) return url;
    return url.replaceFirstMapped(
      RegExp(r'/(\d+)x(\d+)-'),
      (_) => '/${size}x$size-',
    );
  }
}
