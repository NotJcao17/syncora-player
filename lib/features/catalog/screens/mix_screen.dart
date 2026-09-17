import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../auth/local_mode_provider.dart';
import '../../home/mixes/mix_models.dart';
import '../../home/mixes/mix_providers.dart';
import '../save_collection_service.dart';
import '../widgets/collection_scaffold.dart';

/// Detalle de un mix generado por Syncora (`/mix/:key`).
///
/// La lista viene de [mixByKeyProvider], que lee la tirada ya congelada de la
/// sesión: entrar, salir y volver a entrar muestra **siempre lo mismo**. No
/// hay "regenerar" acá a propósito — el mix cambia al cambiar su periodo (día
/// o semana, según el tipo) o al reabrir la app, no porque el usuario vuelva
/// a abrir la pantalla.
class MixScreen extends ConsumerStatefulWidget {
  final String mixKey;

  const MixScreen({super.key, required this.mixKey});

  @override
  ConsumerState<MixScreen> createState() => _MixScreenState();
}

class _MixScreenState extends ConsumerState<MixScreen> {
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final mixesAsync = ref.watch(mixesProvider);
    final mix = ref.watch(mixByKeyProvider(widget.mixKey));

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

    return CollectionScaffold(
      label: 'Mix',
      title: mix.title,
      subtitle: '${mix.subtitle} • ${mix.tracks.length} canciones',
      coverUrl: mix.coverUrl,
      tracks: mix.tracks,
      contextId: 'mix_${mix.key}',
      actions: [
        IconButton(
          icon: _isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.secondary),
                )
              : Icon(AppIcons.broken(SolarIcons.AddCircle), color: AppTheme.secondary, size: 24),
          onPressed: _isSaving ? null : () => _save(mix),
          tooltip: 'Guardar este mix como playlist',
        ),
      ],
    );
  }

  Future<void> _save(SyncoraMix mix) async {
    if (!ref.read(canEditProvider)) {
      AppToast.show(context, message: 'Sin conexión: no se puede guardar ahora');
      return;
    }
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      // Acá y solo acá el mix toca la base de datos: a partir de este momento
      // es una playlist normal del usuario, congelada, que ya no cambia.
      await saveTracksAsPlaylist(
        title: mix.savedTitle(DateTime.now()),
        description: mix.subtitle,
        tracks: mix.tracks,
        dao: ref.read(playlistDaoProvider),
        supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
      );
      if (!mounted) return;
      AppToast.show(context, message: 'Mix guardado en tu biblioteca');
    } catch (_) {
      if (!mounted) return;
      AppToast.show(context, message: 'No se pudo guardar el mix');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
