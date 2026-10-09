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
/// | Guardada de otro usuario | no | **no** |
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
///
/// Una playlist guardada de otro usuario es de solo lectura: la mantiene su
/// dueño y el sync la reemplaza con la original.
bool canEditPlaylistManually(Playlist playlist) =>
    !playlist.isLiked && !playlist.isGenerated && !playlist.isFollowed;

/// ¿Se le pueden agregar pistas, desde dentro o desde "Agregar a playlist"?
///
/// Más permisiva que [canEditPlaylistManually] en un caso: **"Tus me gusta" sí
/// acepta**, porque agregar una canción ahí es exactamente lo que significa
/// marcarla con me gusta. Las generadas no aceptan nada.
bool canAddTracksToPlaylist(Playlist playlist) => !playlist.isGenerated && !playlist.isFollowed;

/// ¿Se puede compartir por enlace?
///
/// Solo las propias con cuenta: el enlace apunta a la fila de Supabase, que
/// no existe en modo local. "Tus me gusta" y "On Repeat" no se comparten.
/// Una guardada sí deja copiar su enlace (ya es pública), pero eso no pasa
/// por aquí: no se puede publicar ni dejar de compartir lo que es de otro.
bool canSharePlaylist(Playlist playlist) =>
    !playlist.isLiked && !playlist.isGenerated && !playlist.isFollowed;
