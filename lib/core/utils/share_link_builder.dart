/// Construye los enlaces que la app copia al portapapeles.
///
/// Se usa una URL `https` y no el esquema propio (`syncoraplayer://…`) porque
/// los deep links no son clicables: WhatsApp, notas y correo solo convierten en
/// enlace lo que empieza por `http(s)`, así que el esquema propio llegaba como
/// texto plano.
///
/// La web (`syncora-web`, `src/pages/playlist.astro`) muestra la playlist en
/// solo lectura y ofrece abrirla en la app con `syncoraplayer://playlist/<id>`.
/// Solo se comparten playlists: canciones y álbumes no tienen vista en la web.
class ShareLinkBuilder {
  static const String baseUrl = 'https://syncoraplayer.app';

  /// [remoteId] es el id de la playlist en Supabase.
  static String playlist(String remoteId) => '$baseUrl/playlist/$remoteId';
}
