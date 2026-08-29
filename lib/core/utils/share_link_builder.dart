/// Construye los enlaces que la app copia al portapapeles.
///
/// Se usa el esquema propio (`syncoraplayer://playlist/123`) y no una URL
/// `https://`: no existe ningún sitio publicado detrás de un dominio propio, así
/// que un enlace `https` se veía como un enlace normal pero al abrirlo daba
/// error de DNS. El deep link, en cambio, abre la app directamente en quien la
/// tenga instalada (registrado en `AndroidManifest.xml`).
///
/// Si algún día existe la web, basta cambiar [scheme] por el dominio y añadir
/// los App Links correspondientes — el resto de la app no se entera.
class ShareLinkBuilder {
  static const String scheme = 'syncoraplayer';

  static String track(String id) => _build('track', id);

  static String playlist(String id) => _build('playlist', id);

  static String album(String id) => _build('album', id);

  static String _build(String type, String id) => '$scheme://$type/$id';
}
