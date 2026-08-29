/// Construye los enlaces que la app copia al portapapeles.
///
/// Se usa una URL `https` y no el esquema propio (`syncoraplayer://…`) porque
/// los deep links no son clicables: WhatsApp, notas y correo solo convierten en
/// enlace lo que empieza por `http(s)`, así que el esquema propio llegaba como
/// texto plano.
///
/// [baseUrl] apunta al dominio previsto para la landing, todavía sin publicar:
/// hasta que exista, el enlace se puede compartir y abrir, pero mostrará el 404
/// de Netlify. La landing es la que después debe redirigir al deep link o
/// mostrar la vista previa.
class ShareLinkBuilder {
  static const String baseUrl = 'https://syncora.netlify.app';

  static String track(String id) => _build('track', id);

  static String playlist(String id) => _build('playlist', id);

  static String album(String id) => _build('album', id);

  static String _build(String type, String id) => '$baseUrl/$type/$id';
}
