import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
import '../../../core/widgets/ai_generation_steps.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/services/ai_assistant_service.dart';
import '../../library/import_export/playlist_import_export_service.dart';
import '../player_models.dart';
import '../player_providers.dart';

/// Fase 7.F.2 -- "Crear cola con IA" / "Mejorar cola con IA".
void showAiCreateQueueSheet(BuildContext context, WidgetRef ref, {bool autoImprove = false}) {
  final isConnected = ref.read(isConnectedProvider).value ?? true;
  if (!isConnected) {
    AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
    return;
  }
  AppBottomSheet.show(
    context: context,
    title: autoImprove ? 'Mejorar cola con IA' : 'Crear cola con IA',
    maxHeightFactor: 0.9,
    child: _AiCreateQueueFlow(autoImprove: autoImprove),
  );
}

enum _Step { form, callingAi, matching, preview, applying }

const List<int> _kCountOptions = [10, 25, 50, 100];
const int _kDefaultCount = 25;
const int _kHardCountCap = 100; // D-5 / validate_request.ts MAX_REQUESTED_COUNT.create_queue

class _AiCreateQueueFlow extends ConsumerStatefulWidget {
  final bool autoImprove;
  const _AiCreateQueueFlow({required this.autoImprove});

  @override
  ConsumerState<_AiCreateQueueFlow> createState() => _AiCreateQueueFlowState();
}

class _AiCreateQueueFlowState extends ConsumerState<_AiCreateQueueFlow> {
  final _promptController = TextEditingController();

  late _Step _step;
  late bool _basedOnCurrent;
  late bool _interleave;
  late int _count;
  String? _formError;

  bool _isSubmitting = false;

  int _matchCurrent = 0;
  int _matchTotal = 0;
  String _matchCurrentName = '';

  List<DeezerTrack> _allMatched = const [];
  final Set<int> _excludedTrackIds = {};
  List<RawImportTrack> _unmatched = const [];

  @override
  void initState() {
    super.initState();
    _count = _kDefaultCount;
    _interleave = true;
    _basedOnCurrent = widget.autoImprove;
    _step = _Step.form;
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  List<DeezerTrack> get _includedTracks =>
      _allMatched.where((t) => !_excludedTrackIds.contains(t.id)).toList();

  int _clampInt(int value, int min, int max) => value < min ? min : (value > max ? max : value);

  List<Map<String, dynamic>> _buildQueueContext() {
    final state = ref.read(syncoraPlayerControllerProvider.notifier).state;
    final seen = <String>{};
    final tracks = <SyncoraTrack>[];
    void add(SyncoraTrack t) {
      if (seen.add(t.id)) tracks.add(t);
    }

    final current = state.currentTrack;
    if (current != null) add(current);
    for (final t in state.manualQueue) {
      add(t);
    }
    for (final t in state.autoQueue) {
      add(t);
    }

    const absurdThreshold = 3000;
    const sampledCap = 1500;
    var effective = tracks;
    if (tracks.length > absurdThreshold) {
      final freq = <String, int>{};
      for (final t in tracks) {
        freq[t.artist] = (freq[t.artist] ?? 0) + 1;
      }
      final rest = current != null ? tracks.skip(1).toList() : tracks;
      final sorted = List<SyncoraTrack>.from(rest)
        ..sort((a, b) => (freq[b.artist] ?? 0).compareTo(freq[a.artist] ?? 0));
      final budget = current != null ? sampledCap - 1 : sampledCap;
      effective = [?current, ...sorted.take(budget)];
    }

    return effective.map((t) => {'id': t.id, 'title': t.title, 'artist': t.artist}).toList();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final isConnected = ref.read(isConnectedProvider).value ?? true;
    if (!isConnected) {
      AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
      return;
    }

    final prompt = _promptController.text.trim();
    final contextTracks = _basedOnCurrent ? _buildQueueContext() : const <Map<String, dynamic>>[];

    if (prompt.isEmpty && contextTracks.isEmpty) {
      setState(() {
        _step = _Step.form;
        _formError = _basedOnCurrent
            ? 'La cola actual está vacía. Escribe una descripción para crear una cola nueva.'
            : 'Escribe una descripción o elige "Basada en la cola actual".';
      });
      return;
    }

    setState(() {
      _formError = null;
      _isSubmitting = true;
    });

    try {
      final askCount = _clampInt((_count * 1.3).round(), 1, _kHardCountCap);
      await _generate(
        prompt: prompt.isEmpty ? null : prompt,
        contextTracks: contextTracks.isEmpty ? null : contextTracks,
        count: askCount,
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _generate({
    String? prompt,
    List<Map<String, dynamic>>? contextTracks,
    int? count,
  }) async {
    setState(() => _step = _Step.callingAi);

    final service = ref.read(aiAssistantServiceProvider);
    Map<String, dynamic> result;
    try {
      result = await service.createQueue(
        prompt: prompt,
        contextTracks: contextTracks,
        interleave: _interleave,
        count: count,
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
    if (!mounted) return;
    final deezerApi = ref.read(deezerApiProvider);
    final service = PlaylistImportExportService(deezerApi);
    final matched = <DeezerTrack>[];
    final unmatched = <RawImportTrack>[];

    final displayTotal = _count;
    setState(() {
      _step = _Step.matching;
      _matchTotal = displayTotal;
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
          _matchCurrent = progress.current.clamp(0, displayTotal);
          _matchTotal = displayTotal;
          _matchCurrentName = progress.currentTrackName;
        });
      }
    } catch (_) {}

    if (!mounted) return;

    final trimmed = PlaylistImportExportService.trimToCount(matched, _count);

    setState(() {
      _allMatched = trimmed;
      _excludedTrackIds.clear();
      _unmatched = unmatched;
      _step = _Step.preview;
    });

    if (trimmed.isEmpty) {
      AppToast.show(context, message: 'Ninguna de las sugerencias de la IA se encontró en Deezer.');
    }
  }

  Future<void> _apply() async {
    final included = _includedTracks;
    if (included.isEmpty) {
      AppToast.show(context, message: 'No hay canciones seleccionadas para agregar.');
      return;
    }
    setState(() => _step = _Step.applying);

    final syncoraTracks = included.map((t) => t.toSyncoraTrack(isAiGenerated: true)).toList();
    final controller = ref.read(syncoraPlayerControllerProvider.notifier);
    if (_interleave) {
      controller.interleaveIntoAutoQueue(syncoraTracks);
    } else {
      controller.addAllToQueue(syncoraTracks);
    }

    if (!mounted) return;
    AppBottomSheet.pop(context);
    AppToast.show(
      context,
      message: _interleave
          ? '${syncoraTracks.length} canciones intercaladas en la cola con IA'
          : '${syncoraTracks.length} canciones agregadas a la cola con IA',
    );
  }

  void _toggleTrack(DeezerTrack track) {
    setState(() {
      if (_excludedTrackIds.contains(track.id)) {
        _excludedTrackIds.remove(track.id);
      } else {
        _excludedTrackIds.add(track.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _Step.form:
        return _buildForm();
      case _Step.callingAi:
        return const AiGeneratingIndicator(label: 'Generando canciones para tu cola con IA...');
      case _Step.matching:
        return AiMatchingProgress(current: _matchCurrent, total: _matchTotal, currentTrackName: _matchCurrentName);
      case _Step.preview:
      case _Step.applying:
        return _buildPreview();
    }
  }

  // --- Paso 1: formulario -------------------------------------------------

  Widget _buildForm() {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        const Text(
          'Describe qué quieres escuchar (opcional si usas la cola actual)',
          style: TextStyle(color: AppTheme.secondary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _promptController,
          maxLines: 3,
          maxLength: 600,
          style: const TextStyle(color: AppTheme.primary),
          decoration: InputDecoration(
            hintText: 'Ej: continúa con algo más movido, sin bajar el ánimo',
            hintStyle: const TextStyle(color: AppTheme.muted, fontSize: 13),
            filled: true,
            fillColor: AppTheme.surfaceHover,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            counterStyle: const TextStyle(color: AppTheme.muted, fontSize: 11),
          ),
        ),
        const SizedBox(height: 20),
        const Text('Origen', style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _choiceChip('Cola nueva', !_basedOnCurrent, () => setState(() => _basedOnCurrent = false)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _choiceChip(
                  'Basada en la cola actual', _basedOnCurrent, () => setState(() => _basedOnCurrent = true)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('Cómo agregarla', style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _choiceChip('Intercalar', _interleave, () => setState(() => _interleave = true)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _choiceChip('Cola manual', !_interleave, () => setState(() => _interleave = false)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('Cantidad de canciones', style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        _buildCountDropdown(),
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
                label: Text(
                  widget.autoImprove ? 'Mejorar cola con IA' : 'Crear cola con IA',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
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
          items: _kCountOptions
              .map((c) => DropdownMenuItem<int>(value: c, child: Text('$c canciones')))
              .toList(),
          onChanged: (val) {
            if (val != null) setState(() => _count = val);
          },
        ),
      ),
    );
  }

  // --- Paso 4: vista previa ------------------------------------------------

  Widget _buildPreview() {
    final included = _includedTracks;
    final isApplying = _step == _Step.applying;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            '${included.length} canciones seleccionadas'
            '${_unmatched.isNotEmpty ? ' · ${_unmatched.length} no encontradas' : ''}',
            style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
          ),
        ),
        const Divider(color: AppTheme.surfaceHover, height: 1),
        Flexible(
          child: AiMatchedTrackList(
            tracks: _allMatched,
            excludedTrackIds: _excludedTrackIds,
            onToggle: _toggleTrack,
          ),
        ),
        if (_unmatched.isNotEmpty)
          AiUnmatchedSuggestionsSection(labels: _unmatched.map((u) => u.toString()).toList()),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: isApplying ? null : () => AppBottomSheet.pop(context),
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
                  onPressed: isApplying || included.isEmpty ? null : _apply,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: AppTheme.background,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: isApplying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.background),
                        )
                      : Text(
                          _interleave ? 'Intercalar en la cola' : 'Agregar a la cola',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
