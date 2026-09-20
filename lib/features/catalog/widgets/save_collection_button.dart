import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../auth/local_mode_provider.dart';
import '../../player/player_models.dart';
import '../save_collection_service.dart';

/// Playlist local ya creada a partir de [sourceRef], si existe.
///
/// `autoDispose` y por `sourceRef`: se recalcula al volver a la pantalla, así
/// que si el usuario borró la copia desde Biblioteca el botón vuelve a
/// ofrecerse. Y como la clave de un mix lleva su periodo, cuando el mix se
/// regenera la clave cambia y el botón reaparece solo — que es justo lo que se
/// quiere: la copia guardada era del mix anterior.
final savedCollectionProvider =
    FutureProvider.autoDispose.family<int?, String>((ref, sourceRef) async {
  final playlist = await ref.watch(playlistDaoProvider).getPlaylistBySourceRef(sourceRef);
  return playlist?.id;
});

/// Botón "guardar una copia en mi biblioteca", con estado.
///
/// Antes no tenía estado: tras guardar, el icono seguía igual, así que el
/// usuario creía que no había pasado nada, volvía a pulsarlo y terminaba con
/// la misma playlist dos veces en su biblioteca. Ahora, si ya existe una copia
/// de esta misma fuente, el botón se muestra como "Guardada" y lleva a la
/// copia en vez de crear otra.
class SaveCollectionButton extends ConsumerStatefulWidget {
  /// Identificador de la fuente: `deezer_playlist:1234`, `mix:<clave>`…
  final String sourceRef;

  final String title;
  final String? description;
  final List<SyncoraTrack> tracks;

  /// Texto del aviso al terminar de guardar.
  final String savedMessage;

  const SaveCollectionButton({
    super.key,
    required this.sourceRef,
    required this.title,
    required this.tracks,
    this.description,
    this.savedMessage = 'Guardada en tu biblioteca',
  });

  @override
  ConsumerState<SaveCollectionButton> createState() => _SaveCollectionButtonState();
}

class _SaveCollectionButtonState extends ConsumerState<SaveCollectionButton> {
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final savedId = ref.watch(savedCollectionProvider(widget.sourceRef)).value;
    final isSaved = savedId != null;

    return IconButton(
      icon: _isSaving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.secondary),
            )
          : Icon(
              isSaved ? AppIcons.bold(SolarIcons.CheckCircle) : AppIcons.broken(SolarIcons.AddCircle),
              color: isSaved
                  ? AppTheme.accent
                  : (widget.tracks.isEmpty ? AppTheme.muted : AppTheme.secondary),
              size: 24,
            ),
      onPressed: _isSaving || widget.tracks.isEmpty
          ? null
          : (isSaved ? () => context.push('/playlist/$savedId') : _save),
      tooltip: isSaved
          // Se dice "copia" a propósito: Syncora no sigue colecciones remotas,
          // las copia, y el usuario tiene que saber que lo guardado no se va a
          // actualizar solo.
          ? 'Ya tienes una copia — abrir en tu biblioteca'
          : 'Guardar una copia en mi biblioteca',
    );
  }

  Future<void> _save() async {
    // Online-First (Pitfall #28): sin conexión y con cuenta, la playlist solo
    // llegaría a Drift y el siguiente sync la podaría.
    if (!ref.read(canEditProvider)) {
      AppToast.show(context, message: 'Sin conexión: no se puede guardar ahora');
      return;
    }
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      await ensureCollectionSaved(
        sourceRef: widget.sourceRef,
        title: widget.title,
        description: widget.description,
        tracks: widget.tracks,
        dao: ref.read(playlistDaoProvider),
        supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
      );
      ref.invalidate(savedCollectionProvider(widget.sourceRef));
      if (!mounted) return;
      AppToast.show(context, message: widget.savedMessage);
    } catch (_) {
      if (!mounted) return;
      AppToast.show(context, message: 'No se pudo guardar');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
