/// Construye enlaces compartibles con formato de URL estándar
/// (`https://syncora.app/{tipo}/{id}`), listos para pegar en un navegador.
///
/// Antes se copiaban esquemas de deep link (`syncoraplayer://...`), que no
/// son URLs válidas fuera de la propia app.
class ShareLinkBuilder {
  static const String baseUrl = 'https://syncora.app';

  static String track(String id) => _build('track', id);

  static String playlist(String id) => _build('playlist', id);

  static String album(String id) => _build('album', id);

  static String _build(String type, String id) => '$baseUrl/$type/$id';
}
