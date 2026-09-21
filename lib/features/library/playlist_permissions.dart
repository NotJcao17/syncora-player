import '../../data/local_db/syncora_database.dart';

/// Qué se puede hacer a mano con cada playlist.
///
/// Son dos reglas distintas y conviene no confundirlas, porque "Tus me gusta"
/// cae en distinto lado de cada una:
///
/// | Playlist | Editar (renombrar, borrar, IA, quitar pistas) | Recibir pistas |
/// | :--- | :--- | :--- |
/// | Normal del usuario | sí | sí |
/// | Tus me gusta | no | **sí** — agregar ahí ES marcar me gusta |
/// | On Repeat (generada) | no | **no** |
///
/// Funciones puras y sin Riverpod a propósito, mismo patrón que
/// `computeCanEdit`/`computeAuthRedirect`: la regla se testea sola, y los
/// sitios que la aplican (que son muchos y están repartidos) no pueden
/// divergir sin que se note.

/// ¿El usuario puede modificar la playlist en sí?
///
/// Cubre renombrar, cambiar portada, eliminarla, quitarle pistas, quitar
/// duplicados y modificarla con IA.
///
/// "Tus me gusta" y "On Repeat" las mantiene la app. En el caso de "On Repeat"
/// además se regenera sola cada semana, así que cualquier edición manual se
/// perdería en la siguiente pasada sin aviso: esconder los controles es más
/// honesto que dejar al usuario hacer un trabajo que se va a tirar.
bool canEditPlaylistManually(Playlist playlist) => !playlist.isLiked && !playlist.isGenerated;

/// ¿Se le pueden agregar pistas, desde dentro o desde "Agregar a playlist"?
///
/// Más permisiva que [canEditPlaylistManually] en un caso: **"Tus me gusta" sí
/// acepta**, porque agregar una canción ahí es exactamente lo que significa
/// marcarla con me gusta. Las generadas no aceptan nada.
bool canAddTracksToPlaylist(Playlist playlist) => !playlist.isGenerated;
