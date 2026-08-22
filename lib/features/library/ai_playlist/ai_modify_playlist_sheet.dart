import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/ai_generation_steps.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/services/ai_assistant_service.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../import_export/playlist_import_export_service.dart';

/// Fase 7.F.3 -- "Modificar playlist con IA". Entrada desde el menú de 3
/// puntos de cada playlist en Biblioteca (`_showPlaylistOptionsMenu` en
/// `library_screen.dart`). Dos modos elegidos con un toggle en el propio
/// formulario:
///  - **Quitar**: la IA solo puede señalar ids que ya están en la playlist
///    (D-7, `schemas.ts#modifyPlaylistRemoveSchema`) -- cero llamadas a
///    Deezer, la vista previa opera directo sobre `PlaylistTrack` local con
///    checkboxes premarcados.
///  - **Agregar**: mismo esqueleto que 7.F.1/7.F.2 (generar -> matchear
///    contra Deezer -> vista previa editable con +/-), reusando
///    `PlaylistImportExportService.processImport`/`parseTrackSuggestions`/
///    `trimToCount` y los widgets de `core/widgets/ai_generation_steps.dart`.
void showAiModifyPlaylistSheet(BuildContext context, WidgetRef ref, Playlist playlist) {
  AppBottomSheet.show(
    context: context,
    title: 'Modificar playlist con IA',
    maxHeightFactor: 0.9,
    child: _AiModifyPlaylistFlow(playlist: playlist),
  );
}

enum _Mode { remove, add }

enum _Step { form, callingAi, matching, preview, applying }

const List<int> _kCountOptions = [10, 25, 50, 100];
const int _kDefaultCount = 25;
const int _kHardCountCap = 100; // D-5 / validate_request.ts MAX_REQUESTED_COUNT.modify_playlist_add

class _AiModifyPlaylistFlow extends ConsumerStatefulWidget {
  final Playlist playlist;
  const _AiModifyPlaylistFlow({required this.playlist});

  @override
  ConsumerState<_AiModifyPlaylistFlow> createState() => _AiModifyPlaylistFlowState();
}

class _AiModifyPlaylistFlowState extends ConsumerState<_AiModifyPlaylistFlow> {
  final _promptController = TextEditingController();

  _Mode _mode = _Mode.add;
  _Step _step = _Step.form;
  int _count = _kDefaultCount;
  String? _formError;
  bool _isSubmitting = false;

  int _matchCurrent = 0;
  int _matchTotal = 0;
  String _matchCurrentName = '';

  // Modo agregar: sugerencias ya matcheadas contra Deezer.
  List<DeezerTrack> _addMatched = const [];
  final Set<int> _addExcludedTrackIds = {};
  List<RawImportTrack> _addUnmatched = const [];

  // Modo quitar: entradas locales existentes que la IA marcó para borrar.
  // Empieza todas marcadas -- el usuario desmarca las que quiere conservar.
  List<PlaylistTrack> _removeCandidates = const [];
  final Set<int> _removeCheckedEntryIds = {};

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  List<DeezerTrack> get _addIncludedTracks =>
      _addMatched.where((t) => !_addExcludedTrackIds.contains(t.id)).toList();

  List<PlaylistTrack> get _removeIncludedTracks =>
      _removeCandidates.where((t) => _removeCheckedEntryIds.contains(t.id)).toList();

  int _clampInt(int value, int min, int max) => value < min ? min : (value > max ? max : value);

  Future<List<PlaylistTrack>> _loadPlaylistTracks() {
    final dao = ref.read(playlistDaoProvider);
    return dao.getTracksOrdered(widget.playlist.id);
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      setState(() => _formError = _mode == _Mode.remove
          ? 'Describe qué canciones quieres quitar.'
          : 'Describe qué canciones quieres agregar.');
      return;
    }
    setState(() {
      _formError = null;
      _isSubmitting = true;
    });

    try {
      final tracks = await _loadPlaylistTracks();
      if (!mounted) return;
      if (_mode == _Mode.remove) {
        await _generateRemove(prompt: prompt, tracks: tracks);
      } else {
        await _generateAdd(prompt: prompt, tracks: tracks);
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _generateRemove({required String prompt, required List<PlaylistTrack> tracks}) async {
    if (tracks.isEmpty) {
      setState(() => _formError = 'Esta playlist está vacía, no hay nada que quitar.');
      return;
    }
    setState(() => _step = _Step.callingAi);

    final contextTracks = tracks
        .map((t) => {'id': t.trackId.toString(), 'title': t.title, 'artist': t.artistName})
        .toList();

    final service = ref.read(aiAssistantServiceProvider);
    Map<String, dynamic> result;
    try {
      result = await service.modifyPlaylistRemove(prompt: prompt, contextTracks: contextTracks);
    } on AiAssistantException catch (e) {
      if (!mounted) return;
      setState(() => _step = _Step.form);
      AppToast.show(context, message: e.message);
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _step = _Step.form);
      AppToast.show(context, message: 'No se pudo contactar al asistente de IA. Revisa tu conexión e intenta de nuevo.');
      return;
    }

    if (!mounted) return;
    final idsRaw = result['idsToRemove'];
    final ids = idsRaw is List ? idsRaw.whereType<String>().toSet() : const <String>{};
    final candidates = tracks.where((t) => ids.contains(t.trackId.toString())).toList();

    if (candidates.isEmpty) {
      setState(() => _step = _Step.form);
      AppToast.show(context, message: 'La IA no identificó ninguna canción para quitar según esa descripción.');
      return;
    }

    setState(() {
      _removeCandidates = candidates;
      _removeCheckedEntryIds
        ..clear()
        ..addAll(candidates.map((t) => t.id));
      _step = _Step.preview;
    });
  }

  Future<void> _generateAdd({required String prompt, required List<PlaylistTrack> tracks}) async {
    setState(() => _step = _Step.callingAi);

    final contextTracks = tracks
        .map((t) => {'id': t.trackId.toString(), 'title': t.title, 'artist': t.artistName})
        .toList();
    final askCount = _clampInt((_count * 1.3).round(), 1, _kHardCountCap);

    final service = ref.read(aiAssistantServiceProvider);
    Map<String, dynamic> result;
    try {
      result = await service.modifyPlaylistAdd(
        prompt: prompt,
        contextTracks: contextTracks.isEmpty ? null : contextTracks,
        count: askCount,
      );
    } on AiAssistantException catch (e) {
      if (!mounted) return;
      setState(() => _step = _Step.form);
      AppToast.show(context, message: e.message);
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _step = _Step.form);
      AppToast.show(context, message: 'No se pudo contactar al asistente de IA. Revisa tu conexión e intenta de nuevo.');
      return;
    }

    final rawTracks = PlaylistImportExportService.parseTrackSuggestions(result['tracks']);
    if (rawTracks.isEmpty) {
      if (!mounted) return;
      setState(() => _step = _Step.form);
      AppToast.show(context, message: 'La IA no devolvió ninguna canción. Intenta con otra descripción.');
      return;
    }

    await _matchAndSettle(rawTracks);
  }

  Future<void> _matchAndSettle(List<RawImportTrack> rawTracks) async {
    // Mismo cuidado que 7.F.1/7.F.2: `_generate*` llega hasta acá recién
    // después de un `await` real a la Edge Function -- si el usuario cerró
    // la hoja mientras tanto, `ref` ya no es seguro de usar.
    if (!mounted) return;
    final deezerApi = ref.read(deezerApiProvider);
    final service = PlaylistImportExportService(deezerApi);
    final matched = <DeezerTrack>[];
    final unmatched = <RawImportTrack>[];

    setState(() {
      _step = _Step.matching;
      _matchTotal = rawTracks.length;
      _matchCurrent = 0;
      _matchCurrentName = '';
    });

    try {
      await for (final progress in service.processImport(
        rawTracks: rawTracks,
        outMatched: matched,
        outUnmatched: unmatched,
      )) {
        if (!mounted) return;
        setState(() {
          _matchCurrent = progress.current;
          _matchTotal = progress.total;
          _matchCurrentName = progress.currentTrackName;
        });
      }
    } catch (_) {
      // processImport ya cuenta los fallos por pista como no-matcheadas;
      // esto solo cubre un fallo catastrófico inesperado del stream.
    }

    if (!mounted) return;
    final trimmed = PlaylistImportExportService.trimToCount(matched, _count);

    setState(() {
      _addMatched = trimmed;
      _addExcludedTrackIds.clear();
      _addUnmatched = unmatched;
      _step = _Step.preview;
    });

    if (trimmed.isEmpty) {
      AppToast.show(context, message: 'Ninguna de las sugerencias de la IA se encontró en Deezer.');
    }
  }

  Future<void> _applyRemove() async {
    final included = _removeIncludedTracks;
    if (included.isEmpty) {
      AppToast.show(context, message: 'No hay canciones seleccionadas para quitar.');
      return;
    }
    setState(() => _step = _Step.applying);
    try {
      final service = PlaylistImportExportService(ref.read(deezerApiProvider));
      await service.removeTracksFromPlaylist(
        playlistId: widget.playlist.id,
        remotePlaylistId: widget.playlist.remoteId,
        tracksToRemove: included,
        dao: ref.read(playlistDaoProvider),
        supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
      );
      if (!mounted) return;
      AppBottomSheet.pop(context);
      AppToast.show(context, message: '${included.length} canciones quitadas con IA');
    } catch (_) {
      if (!mounted) return;
      setState(() => _step = _Step.preview);
      AppToast.show(context, message: 'No se pudieron quitar las canciones. Intenta de nuevo.');
    }
  }

  Future<void> _applyAdd() async {
    final included = _addIncludedTracks;
    if (included.isEmpty) {
      AppToast.show(context, message: 'No hay canciones seleccionadas para agregar.');
      return;
    }
    setState(() => _step = _Step.applying);
    try {
      final service = PlaylistImportExportService(ref.read(deezerApiProvider));
      await service.addMatchedTracksToExistingPlaylist(
        playlistId: widget.playlist.id,
        remotePlaylistId: widget.playlist.remoteId,
        matchedTracks: included,
        dao: ref.read(playlistDaoProvider),
        deezerApi: ref.read(deezerApiProvider),
        supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
      );
      if (!mounted) return;
      AppBottomSheet.pop(context);
      AppToast.show(context, message: '${included.length} canciones agregadas con IA');
    } catch (_) {
      if (!mounted) return;
      setState(() => _step = _Step.preview);
      AppToast.show(context, message: 'No se pudieron agregar las canciones. Intenta de nuevo.');
    }
  }

  void _toggleAddTrack(DeezerTrack track) {
    setState(() {
      if (_addExcludedTrackIds.contains(track.id)) {
        _addExcludedTrackIds.remove(track.id);
      } else {
        _addExcludedTrackIds.add(track.id);
      }
    });
  }

  void _toggleRemoveTrack(PlaylistTrack track) {
    setState(() {
      if (_removeCheckedEntryIds.contains(track.id)) {
        _removeCheckedEntryIds.remove(track.id);
      } else {
        _removeCheckedEntryIds.add(track.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _Step.form:
        return _buildForm();
      case _Step.callingAi:
        return const AiGeneratingIndicator();
      case _Step.matching:
        return AiMatchingProgress(current: _matchCurrent, total: _matchTotal, currentTrackName: _matchCurrentName);
      case _Step.preview:
      case _Step.applying:
        return _mode == _Mode.remove ? _buildRemovePreview() : _buildAddPreview();
    }
  }

  // --- Paso 1: formulario -------------------------------------------------

  Widget _buildForm() {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        const Text('Qué quieres hacer', style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _choiceChip('Quitar canciones', _mode == _Mode.remove, () => setState(() => _mode = _Mode.remove))),
            const SizedBox(width: 8),
            Expanded(child: _choiceChip('Agregar canciones', _mode == _Mode.add, () => setState(() => _mode = _Mode.add))),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          _mode == _Mode.remove ? 'Describe qué canciones quitar' : 'Describe qué canciones agregar',
          style: const TextStyle(color: AppTheme.secondary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _promptController,
          maxLines: 3,
          maxLength: 600,
          style: const TextStyle(color: AppTheme.primary),
          decoration: InputDecoration(
            hintText: _mode == _Mode.remove
                ? 'Ej: las canciones más lentas, o las de reguetón'
                : 'Ej: más canciones parecidas a las que ya están, algo más movido',
            hintStyle: const TextStyle(color: AppTheme.muted, fontSize: 13),
            filled: true,
            fillColor: AppTheme.surfaceHover,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            counterStyle: const TextStyle(color: AppTheme.muted, fontSize: 11),
          ),
        ),
        if (_mode == _Mode.add) ...[
          const SizedBox(height: 16),
          const Text('Cantidad de canciones', style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _buildCountDropdown(),
        ],
        if (_formError != null) ...[
          const SizedBox(height: 12),
          Text(_formError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => AppBottomSheet.pop(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.secondary,
                  side: const BorderSide(color: AppTheme.surfaceHover),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Cancelar'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _submit,
                icon: Icon(AppIcons.broken(SolarIcons.StarsMinimalistic), size: 18),
                label: const Text('Continuar', style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: AppTheme.background,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _choiceChip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label, textAlign: TextAlign.center),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppTheme.primary,
      backgroundColor: AppTheme.surfaceHover,
      labelStyle: TextStyle(
        color: selected ? AppTheme.background : AppTheme.primary,
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
      showCheckmark: false,
      shape: StadiumBorder(side: BorderSide(color: selected ? AppTheme.primary : AppTheme.surfaceHover)),
    );
  }

  Widget _buildCountDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: AppTheme.surfaceHover, borderRadius: BorderRadius.circular(12)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          isExpanded: true,
          value: _count,
          dropdownColor: AppTheme.surface,
          style: const TextStyle(color: AppTheme.primary, fontSize: 13),
          items: _kCountOptions.map((c) => DropdownMenuItem<int>(value: c, child: Text('$c canciones'))).toList(),
          onChanged: (val) {
            if (val != null) setState(() => _count = val);
          },
        ),
      ),
    );
  }

  // --- Paso 4 (modo agregar): vista previa --------------------------------

  Widget _buildAddPreview() {
    final included = _addIncludedTracks;
    final isApplying = _step == _Step.applying;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            '${included.length} canciones seleccionadas'
            '${_addUnmatched.isNotEmpty ? ' · ${_addUnmatched.length} no encontradas' : ''}',
            style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
          ),
        ),
        const Divider(color: AppTheme.surfaceHover, height: 1),
        Flexible(
          child: AiMatchedTrackList(
            tracks: _addMatched,
            excludedTrackIds: _addExcludedTrackIds,
            onToggle: _toggleAddTrack,
          ),
        ),
        if (_addUnmatched.isNotEmpty)
          AiUnmatchedSuggestionsSection(labels: _addUnmatched.map((u) => u.toString()).toList()),
        _buildPreviewActions(
          isBusy: isApplying,
          confirmEnabled: included.isNotEmpty,
          confirmLabel: 'Agregar a la playlist',
          onConfirm: _applyAdd,
        ),
      ],
    );
  }

  // --- Paso 4 (modo quitar): vista previa ----------------------------------

  Widget _buildRemovePreview() {
    final included = _removeIncludedTracks;
    final isApplying = _step == _Step.applying;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            '${included.length} de ${_removeCandidates.length} canciones marcadas para quitar',
            style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
          ),
        ),
        const Divider(color: AppTheme.surfaceHover, height: 1),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: _removeCandidates.length,
            itemBuilder: (context, index) {
              final track = _removeCandidates[index];
              final checked = _removeCheckedEntryIds.contains(track.id);
              return CheckboxListTile(
                value: checked,
                onChanged: (_) => _toggleRemoveTrack(track),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                activeColor: AppTheme.primary,
                checkColor: AppTheme.background,
                secondary: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: track.coverUrl.isNotEmpty
                        ? CachedNetworkImage(imageUrl: track.coverUrl, fit: BoxFit.cover)
                        : Container(color: AppTheme.surfaceHover),
                  ),
                ),
                title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text(track.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.secondary, fontSize: 12)),
              );
            },
          ),
        ),
        _buildPreviewActions(
          isBusy: isApplying,
          confirmEnabled: included.isNotEmpty,
          confirmLabel: 'Quitar de la playlist',
          onConfirm: _applyRemove,
          destructive: true,
        ),
      ],
    );
  }

  Widget _buildPreviewActions({
    required bool isBusy,
    required bool confirmEnabled,
    required String confirmLabel,
    required VoidCallback onConfirm,
    bool destructive = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: isBusy ? null : () => AppBottomSheet.pop(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.secondary,
                side: const BorderSide(color: AppTheme.surfaceHover),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Cancelar'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: isBusy || !confirmEnabled ? null : onConfirm,
              style: ElevatedButton.styleFrom(
                backgroundColor: destructive ? Colors.redAccent : AppTheme.primary,
                foregroundColor: destructive ? Colors.white : AppTheme.background,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: isBusy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: destructive ? Colors.white : AppTheme.background),
                    )
                  : Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
