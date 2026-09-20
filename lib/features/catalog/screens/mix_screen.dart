import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../auth/local_mode_provider.dart';
import '../../home/mixes/mix_models.dart';
import '../../home/mixes/mix_providers.dart';
import '../../home/widgets/mix_cover.dart';
import '../save_collection_service.dart';
import '../widgets/collection_scaffold.dart';
import '../widgets/save_collection_button.dart';

/// Detalle de un mix generado por Syncora (`/mix/:key`).
///
/// La lista viene de [mixByKeyProvider], que lee la tirada ya congelada de la
/// sesión: entrar, salir y volver a entrar muestra **siempre lo mismo**. El mix
/// cambia al cambiar su periodo (día o semana, según el tipo) o al reabrir la
/// app, no porque el usuario vuelva a abrir la pantalla.
///
/// Guardarlo crea una copia congelada. Como el `sourceRef` de esa copia lleva
/// pegada la clave del mix —y la clave lleva su periodo—, cuando el mix se
/// regenera el botón vuelve a ofrecer guardarlo: la copia que existe es del mix
/// anterior, no de este.
///
/// "On Repeat" no pasa por acá: es una playlist permanente
/// (`on_repeat_service.dart`), no un mix efímero.
class MixScreen extends ConsumerWidget {
  final String mixKey;

  const MixScreen({super.key, required this.mixKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mixesAsync = ref.watch(mixesProvider);
    final mix = ref.watch(mixByKeyProvider(mixKey));

    if (mixesAsync.isLoading && mix == null) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      );
    }

    if (mix == null) {
      // Pasa si se abre el enlace de un mix de otro periodo (o de otra sesión):
      // la tirada de aquel momento ya no existe y no se puede reconstruir.
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(
          message: 'Este mix ya no está disponible. Vuelve a Inicio para ver los de hoy.',
          onRetry: () => ref.invalidate(mixesProvider),
        ),
      );
    }

    final sourceRef = 'mix:${mix.key}';
    final savedTitle = mix.savedTitle(DateTime.now());

    return CollectionScaffold(
      label: 'Mix',
      title: mix.title,
      subtitle: '${mix.subtitle} • ${mix.tracks.length} canciones',
      coverUrl: mix.coverUrl,
      coverOverride: mix.usesGeneratedCover ? MixCover(kind: mix.kind, borderRadius: 20) : null,
      tracks: mix.tracks,
      contextId: 'mix_${mix.key}',
      onBeforeDownload: () => _saveBeforeDownload(context, ref, mix, sourceRef, savedTitle),
      actions: [
        SaveCollectionButton(
          sourceRef: sourceRef,
          // Con fecha: a partir de guardarlo es una foto fija, y sin fecha dos
          // guardados del mismo mix en semanas distintas serían indistinguibles.
          title: savedTitle,
          description: mix.subtitle,
          tracks: mix.tracks,
          savedMessage: 'Mix guardado en tu biblioteca',
        ),
      ],
    );
  }
}

Future<bool> _saveBeforeDownload(
  BuildContext context,
  WidgetRef ref,
  SyncoraMix mix,
  String sourceRef,
  String savedTitle,
) async {
  final dao = ref.read(playlistDaoProvider);
  if (await dao.getPlaylistBySourceRef(sourceRef) != null) return true;

  if (!ref.read(canEditProvider)) {
    if (context.mounted) {
      AppToast.show(context, message: 'Sin conexión: guarda el mix cuando vuelvas a tener red');
    }
    return false;
  }

  try {
    await ensureCollectionSaved(
      sourceRef: sourceRef,
      title: savedTitle,
      description: mix.subtitle,
      tracks: mix.tracks,
      dao: dao,
      supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
    );
    ref.invalidate(savedCollectionProvider(sourceRef));
    if (context.mounted) {
      // Un mix se regenera solo: si no se congelara antes de descargarlo, las
      // pistas descargadas dejarían de corresponder a nada en un día.
      AppToast.show(context, message: 'Mix guardado en tu biblioteca para poder descargarlo');
    }
    return true;
  } catch (_) {
    if (context.mounted) {
      AppToast.show(context, message: 'No se pudo guardar el mix');
    }
    return false;
  }
}
