import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../data/apis/deezer_catalog_providers.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../auth/local_mode_provider.dart';
import '../../home/mixes/mix_engine.dart';
import '../../player/player_models.dart';
import '../save_collection_service.dart';
import '../widgets/collection_scaffold.dart';
import '../widgets/save_collection_button.dart';

/// Radio de un artista (`/artist-radio/:id`).
///
/// Es la misma pieza que alimenta los "Mix de {artista}" de Inicio
/// (`/artist/{id}/radio`), traída a la pantalla de artista para que junto a su
/// discografía y sus canciones populares se pueda arrancar una escucha continua
/// en su estilo.
///
/// Comparte la caché LRU de sesión de `DeezerApi`, así que dentro de un mismo
/// arranque muestra siempre la misma tirada — entrar y salir no la cambia,
/// igual que con los mixes. Al reabrir la app sí, porque la API no es
/// determinista (ver `docs/fases/inicio_y_explorar.md` §2).
///
/// Guardarla crea una copia congelada, como cualquier otra colección que no
/// vive en la biblioteca.
class ArtistRadioScreen extends ConsumerWidget {
  final String artistId;

  const ArtistRadioScreen({super.key, required this.artistId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = int.tryParse(artistId) ?? 0;
    if (id <= 0) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(message: 'Artista no válido'),
      );
    }

    final radioAsync = ref.watch(deezerArtistRadioProvider(id));
    final artist = ref.watch(deezerArtistProvider(id)).value;
    final artistName = artist?.name ?? 'este artista';

    return radioAsync.when(
      loading: () => const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(
          message: 'No pudimos cargar la radio de $artistName',
          onRetry: () => ref.invalidate(deezerArtistRadioProvider(id)),
        ),
      ),
      data: (radio) {
        final tracks = radio.map((t) => t.toSyncoraTrack()).toList();
        final title = 'Radio de $artistName';
        final description = 'Canciones en la línea de $artistName';

        // Con el día pegado: la radio cambia a diario, y sin eso una copia
        // guardada hace un mes bloquearía el botón para siempre.
        final sourceRef = 'artist_radio:$id:${MixEngine.dayKey(DateTime.now())}';
        final savedTitle = '$title · ${_shortDate(DateTime.now())}';

        return CollectionScaffold(
          label: 'Radio',
          title: title,
          subtitle: '${tracks.length} canciones',
          coverUrl: artist?.pictureUrl ?? (tracks.isNotEmpty ? tracks.first.coverUrl : ''),
          tracks: tracks,
          contextId: 'artist_radio_$id',
          emptyMessage: 'Deezer no devolvió canciones para esta radio.',
          onBeforeDownload: () => _saveBeforeDownload(
            context,
            ref,
            sourceRef: sourceRef,
            title: savedTitle,
            description: description,
            tracks: tracks,
          ),
          actions: [
            SaveCollectionButton(
              sourceRef: sourceRef,
              title: savedTitle,
              description: description,
              tracks: tracks,
              savedMessage: 'Radio guardada en tu biblioteca',
            ),
          ],
        );
      },
    );
  }
}

String _shortDate(DateTime now) {
  const meses = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  return '${now.day} ${meses[now.month - 1]}';
}

Future<bool> _saveBeforeDownload(
  BuildContext context,
  WidgetRef ref, {
  required String sourceRef,
  required String title,
  String? description,
  required List<SyncoraTrack> tracks,
}) async {
  final dao = ref.read(playlistDaoProvider);
  if (await dao.getPlaylistBySourceRef(sourceRef) != null) return true;

  if (!ref.read(canEditProvider)) {
    if (context.mounted) {
      AppToast.show(context, message: 'Sin conexión: guarda la radio cuando vuelvas a tener red');
    }
    return false;
  }

  try {
    await ensureCollectionSaved(
      sourceRef: sourceRef,
      title: title,
      description: description,
      tracks: tracks,
      dao: dao,
      supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
    );
    ref.invalidate(savedCollectionProvider(sourceRef));
    if (context.mounted) {
      // Una radio se vuelve a sortear: si no se congelara antes de
      // descargarla, las pistas descargadas dejarían de corresponder a nada.
      AppToast.show(context, message: 'Radio guardada en tu biblioteca para poder descargarla');
    }
    return true;
  } catch (_) {
    if (context.mounted) {
      AppToast.show(context, message: 'No se pudo guardar la radio');
    }
    return false;
  }
}
