import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/track_tile.dart';
import '../../auth/local_mode_provider.dart';
import '../ai_queue/ai_create_queue_sheet.dart';
import '../player_models.dart';
import '../player_providers.dart';

/// Vista compartida de la cola dual de reproducción (Fase 7.A,
/// `docs/plan_fase_7.md` D-1/D-2/D-3): dos secciones visualmente
/// diferenciadas — "A continuación" (manual, FIFO) y "Siguiente de
/// {contexto}" (automática, regenerable) — con reordenar por sección
/// (nunca entre secciones, 7.A.10), deslizar a la izquierda para eliminar,
/// y un modo "Editar" con selección múltiple (eliminar / mover arriba).
///
/// No asume ningún contenedor: quien la invoque decide si va embebida (ej.
/// el sidebar colapsable de escritorio en `app_shell.dart`) o dentro de una
/// hoja modal. Para el caso modal, usa el helper estático [QueueView.showSheet]
/// (P2.4: evita duplicar el mismo `AppBottomSheet.show(...)` en
/// `mini_player.dart` y `player_fullscreen_screen.dart`). Si
/// [onTrackSelected] no es null, se llama tras iniciar la reproducción de
/// una pista desde la cola — el llamador decide qué hacer con eso (ej.
/// cerrar la hoja modal).
class QueueView extends ConsumerStatefulWidget {
  final VoidCallback? onTrackSelected;

  const QueueView({super.key, this.onTrackSelected});

  /// Abre la cola dentro de una hoja modal (`AppBottomSheet`), cerrándola
  /// automáticamente al reproducir una pista.
  static Future<void> showSheet(BuildContext context) {
    return AppBottomSheet.show(
      context: context,
      title: 'Cola de reproducción',
      child: QueueView(onTrackSelected: () => AppBottomSheet.pop(context)),
    );
  }

  @override
  ConsumerState<QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends ConsumerState<QueueView> {
  bool _editMode = false;

  // P1.9: selección por id de pista (no por índice) — un índice queda
  // obsoleto en cuanto la cola avanza (la pista sonó y se consumió) mientras
  // el modo Editar sigue abierto; el id no.
  final Set<String> _selectedManual = {};
  final Set<String> _selectedAuto = {};

  void _toggleEditMode() {
    setState(() {
      _editMode = !_editMode;
      _selectedManual.clear();
      _selectedAuto.clear();
    });
  }

  void _toggleSelected(QueueOrigin origin, String trackId) {
    setState(() {
      final set = origin == QueueOrigin.manual ? _selectedManual : _selectedAuto;
      if (set.contains(trackId)) {
        set.remove(trackId);
      } else {
        set.add(trackId);
      }
    });
  }

  /// Resuelve los índices ACTUALES (en el momento de la acción, no los que
  /// tenía la lista cuando se seleccionó) de los ids marcados dentro de
  /// [tracks]. Un id que ya no está presente (se consumió por reproducción
  /// mientras Editar seguía abierto) simplemente se omite, no falla.
  List<int> _resolveSelectedIndices(List<SyncoraTrack> tracks, Set<String> selectedIds) {
    final indices = <int>[];
    for (var i = 0; i < tracks.length; i++) {
      if (selectedIds.contains(tracks[i].id)) indices.add(i);
    }
    return indices;
  }

  void _deleteSelected() {
    final controller = ref.read(syncoraPlayerControllerProvider.notifier);
    final state = controller.state;

    // Descendente: eliminar de mayor a menor índice para que los índices ya
    // resueltos de la misma sección no se corran entre sí.
    for (final idx in _resolveSelectedIndices(state.manualQueue, _selectedManual).reversed) {
      controller.removeFromQueue(QueueOrigin.manual, idx);
    }
    for (final idx in _resolveSelectedIndices(state.autoQueue, _selectedAuto).reversed) {
      controller.removeFromQueue(QueueOrigin.auto, idx);
    }
    setState(() {
      _selectedManual.clear();
      _selectedAuto.clear();
    });
  }

  void _moveSelectedToTop() {
    final controller = ref.read(syncoraPlayerControllerProvider.notifier);
    final state = controller.state;

    // Ascendente: mover cada seleccionada, en orden, justo después del
    // bloque ya movido al frente — preserva el orden relativo entre ellas.
    final manualIndices = _resolveSelectedIndices(state.manualQueue, _selectedManual);
    for (var i = 0; i < manualIndices.length; i++) {
      controller.reorderQueue(QueueOrigin.manual, manualIndices[i], i);
    }
    final autoIndices = _resolveSelectedIndices(state.autoQueue, _selectedAuto);
    for (var i = 0; i < autoIndices.length; i++) {
      controller.reorderQueue(QueueOrigin.auto, autoIndices[i], i);
    }
    setState(() {
      _selectedManual.clear();
      _selectedAuto.clear();
    });
  }

  /// Humaniza `activeContextId` (ej. `playlist_42`, `downloads`,
  /// `album_17`) para el header de la sección automática. No hay una fuente
  /// de "nombre bonito" disponible aquí sin ir a buscar la playlist/álbum de
  /// nuevo, así que se resuelve un texto genérico por tipo de contexto en
  /// vez de mostrar el id crudo.
  String _contextLabel(String? activeContextId) {
    if (activeContextId == null) return 'la reproducción actual';
    if (activeContextId == 'downloads') return 'tus descargas';
    if (activeContextId.startsWith('playlist_')) return 'esta playlist';
    if (activeContextId.startsWith('album_')) return 'este álbum';
    if (activeContextId.startsWith('artist_')) return 'este artista';
    return 'la reproducción actual';
  }

  /// Keys estables ante reorder: por id de pista, no por posición. Si la
  /// misma pista aparece más de una vez en la sección (duplicado agregado a
  /// propósito por el usuario), se distingue con un índice de ocurrencia
  /// estable (cuántas veces apareció ese id antes de esta posición).
  List<ValueKey<String>> _stableKeysFor(QueueOrigin origin, List<SyncoraTrack> tracks) {
    final counts = <String, int>{};
    return tracks.map((t) {
      final occurrence = counts.update(t.id, (v) => v + 1, ifAbsent: () => 0);
      return ValueKey('${origin.name}_${t.id}_$occurrence');
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // P2.2: seleccionar solo los campos relevantes evita reconstruir toda
    // la vista (incluidas las dos listas reordenables) en cada tick de
    // posición del motor — `manualQueue`/`autoQueue`/`currentTrack` guardan
    // la MISMA referencia entre copyWith() que no las toca, así que el
    // record de abajo compara igual y Riverpod no re-emite.
    final selected = ref.watch(syncoraPlayerControllerProvider.select(
      (c) => (c.state.manualQueue, c.state.autoQueue, c.state.currentTrack, c.state.activeContextId),
    ));
    final manual = selected.$1;
    final auto = selected.$2;
    final current = selected.$3;
    final activeContextId = selected.$4;
    final hasSelection = _selectedManual.isNotEmpty || _selectedAuto.isNotEmpty;

    // P1.10: el empty state completo solo aplica cuando NO suena nada Y
    // ambas colas están vacías — antes se mostraba aunque siguiera sonando
    // una pista, porque solo se miraban las colas.
    //
    // Fase 7.F.2: con la cola totalmente vacía es exactamente el caso de uso
    // principal del modo "cola nueva" (sin contexto que ofrecer) -- sin este
    // botón de acción, el único punto de entrada de "Crear cola con IA"
    // (el de `_buildToolbar`) quedaba inalcanzable justo cuando más sentido
    // tiene usarlo.
    if (current == null && manual.isEmpty && auto.isEmpty) {
      final isConnected = ref.watch(isConnectedProvider).value ?? true;
      // 7.I: la IA necesita el JWT del usuario -- sin cuenta no hay botón
      // que ofrecer acá (D-24), solo el mensaje base del empty state.
      final isLocalMode = ref.watch(localModeProvider);
      return EmptyStateWidget(
        title: 'La cola está vacía',
        message: 'Agrega canciones con "Reproducir a continuación" o "Agregar a la cola" desde cualquier lista.',
        action: isLocalMode
            ? null
            : OutlinedButton.icon(
                onPressed: isConnected
                    ? () => showAiCreateQueueSheet(context, ref)
                    : () => AppToast.show(context, message: 'Sin conexión. Las funciones de IA necesitan internet.'),
                icon: Icon(AppIcons.broken(SolarIcons.StarsMinimalistic), size: 16),
                label: const Text('Crear cola con IA'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  side: const BorderSide(color: AppTheme.surfaceHover),
                ),
              ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildToolbar(manual.length + auto.length, hasSelection),
        Flexible(
          child: CustomScrollView(
            slivers: [
              if (current != null) SliverToBoxAdapter(child: _buildNowPlaying(current)),
              SliverToBoxAdapter(child: _buildSectionHeader('A continuación', manual.length)),
              if (manual.isEmpty)
                SliverToBoxAdapter(
                  child: _buildSectionEmptyMessage(
                    'No has agregado canciones a la cola. Usa "Reproducir a continuación" o "Agregar a la cola" desde el menú de una canción.',
                  ),
                )
              else
                _buildSectionSliver(QueueOrigin.manual, manual),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              SliverToBoxAdapter(child: _buildSectionHeader('Siguiente de ${_contextLabel(activeContextId)}', auto.length)),
              if (auto.isEmpty)
                SliverToBoxAdapter(child: _buildSectionEmptyMessage('No hay más canciones en la reproducción automática.'))
              else
                _buildSectionSliver(QueueOrigin.auto, auto),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
            ],
          ),
        ),
      ],
    );
  }

  /// P1.10: la pista que suena ahora ya no aparece en ninguna de las dos
  /// colas (es un campo propio del estado desde la Fase 7.A) — sin esto
  /// desaparecía por completo de la vista de cola.
  Widget _buildNowPlaying(SyncoraTrack track) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Reproduciendo ahora',
            style: TextStyle(
              color: AppTheme.secondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          TrackTile(track: track, isPlaying: true),
        ],
      ),
    );
  }

  Widget _buildToolbar(int totalCount, bool hasSelection) {
    final controller = ref.read(syncoraPlayerControllerProvider.notifier);
    final selectionCount = _selectedManual.length + _selectedAuto.length;
    // Fase 7.F.2: mismo patrón de gating que los otros 3 puntos de entrada
    // de IA (`library_screen.dart`) -- deshabilitado sin conexión, con
    // tooltip/toast explicando por qué en vez de un botón muerto sin
    // explicación.
    final isConnected = ref.watch(isConnectedProvider).value ?? true;
    // 7.I: sin cuenta, ninguna de las dos entradas de IA de acá aplica --
    // se ocultan (D-24), no solo se deshabilitan.
    final isLocalMode = ref.watch(localModeProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$totalCount canciones en cola',
                style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: _toggleEditMode,
                    icon: Icon(
                      _editMode ? AppIcons.broken(SolarIcons.CloseCircle) : AppIcons.broken(SolarIcons.Pen),
                      size: 16,
                      color: AppTheme.secondary,
                    ),
                    label: Text(
                      _editMode ? 'Listo' : 'Editar',
                      style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => controller.clearQueue(),
                    icon: Icon(AppIcons.broken(SolarIcons.TrashBinMinimalistic), size: 16, color: AppTheme.secondary),
                    label: const Text('Limpiar cola', style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
          if (!isLocalMode)
            Row(
              children: [
                Tooltip(
                  message: isConnected ? 'Crear cola con IA' : 'Sin conexión',
                  child: IconButton(
                    // D-14: mismo ícono (`StarsMinimalistic`) en los 4 puntos
                    // de entrada de IA de la Fase 7.F.
                    icon: Icon(
                      AppIcons.broken(SolarIcons.StarsMinimalistic),
                      color: isConnected ? AppTheme.primary : AppTheme.muted,
                      size: 18,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: isConnected
                        ? () => showAiCreateQueueSheet(context, ref)
                        : () => AppToast.show(context, message: 'Sin conexión. Las funciones de IA necesitan internet.'),
                  ),
                ),
                // D-9 / atajo "✨ Mejorar esta cola": prellena basada-en-cola-
                // actual + intercalar + 25 y dispara directo, sin abrir el
                // panel completo.
                TextButton.icon(
                  onPressed: isConnected
                      ? () => showAiCreateQueueSheet(context, ref, autoImprove: true)
                      : () => AppToast.show(context, message: 'Sin conexión. Las funciones de IA necesitan internet.'),
                  icon: Icon(
                    AppIcons.broken(SolarIcons.StarsMinimalistic),
                    size: 14,
                    color: isConnected ? AppTheme.primary : AppTheme.muted,
                  ),
                  label: Text(
                    'Mejorar esta cola',
                    style: TextStyle(color: isConnected ? AppTheme.primary : AppTheme.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          if (_editMode && hasSelection) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _deleteSelected,
                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                  label: Text(
                    'Eliminar seleccionadas ($selectionCount)',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _moveSelectedToTop,
                  icon: Icon(AppIcons.broken(SolarIcons.AltArrowUp), size: 16, color: AppTheme.primary),
                  label: const Text('Mover arriba', style: TextStyle(color: AppTheme.primary, fontSize: 12)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Text(
        count > 0 ? '$title ($count)' : title,
        style: const TextStyle(
          color: AppTheme.secondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildSectionEmptyMessage(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Text(message, style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
    );
  }

  /// P1.12: un `SliverReorderableList`/`SliverList` por sección dentro del
  /// mismo `CustomScrollView` externo (ver `build()`) — a diferencia de
  /// `ReorderableListView` con `shrinkWrap: true` +
  /// `NeverScrollableScrollPhysics` anidado en un `SingleChildScrollView`
  /// (lo que había antes), esto le da a cada sección un scroll real que
  /// participa del auto-scroll al arrastrar cerca del borde en colas largas.
  Widget _buildSectionSliver(QueueOrigin origin, List<SyncoraTrack> tracks) {
    final controller = ref.read(syncoraPlayerControllerProvider.notifier);
    final selected = origin == QueueOrigin.manual ? _selectedManual : _selectedAuto;
    final keys = _stableKeysFor(origin, tracks);

    if (_editMode) {
      return SliverList.builder(
        itemCount: tracks.length,
        itemBuilder: (ctx, i) {
          final track = tracks[i];
          final isSelected = selected.contains(track.id);
          return KeyedSubtree(
            key: keys[i],
            child: InkWell(
              onTap: () => _toggleSelected(origin, track.id),
              child: Padding(
                padding: const EdgeInsets.only(left: 12.0),
                child: Row(
                  children: [
                    Icon(
                      isSelected ? AppIcons.bold(SolarIcons.CheckCircle) : AppIcons.broken(SolarIcons.CheckCircle),
                      color: isSelected ? AppTheme.primary : AppTheme.muted,
                      size: 22,
                    ),
                    Expanded(
                      child: IgnorePointer(
                        child: TrackTile(track: track, index: i),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }

    return SliverReorderableList(
      itemCount: tracks.length,
      // ignore: deprecated_member_use
      onReorder: (oldIndex, newIndex) {
        controller.reorderQueue(origin, oldIndex, newIndex);
      },
      itemBuilder: (ctx, i) {
        final track = tracks[i];
        final itemKey = keys[i];
        return ReorderableDelayedDragStartListener(
          key: itemKey,
          index: i,
          child: Dismissible(
            key: ValueKey('${itemKey.value}_dismiss'),
            direction: DismissDirection.endToStart,
            onDismissed: (_) {
              controller.removeFromQueue(origin, i);
            },
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              color: Colors.red.withValues(alpha: 0.2),
              child: const Icon(Icons.delete, color: Colors.red),
            ),
            child: TrackTile(
              track: track,
              index: i,
              onTap: () {
                // P1.11: cerrar la hoja de inmediato (síncrono) y disparar
                // playFromQueue sin esperarlo — antes se hacía `await` sobre
                // playFromQueue (puede tardar por extracción de red) ANTES
                // de cerrar, así que si el usuario cerraba la hoja a mano
                // mientras tanto, el pop tardío podía cerrar la pantalla
                // equivocada.
                widget.onTrackSelected?.call();
                controller.playFromQueue(origin, i);
              },
              onRemove: () => controller.removeFromQueue(origin, i),
            ),
          ),
        );
      },
    );
  }
}
