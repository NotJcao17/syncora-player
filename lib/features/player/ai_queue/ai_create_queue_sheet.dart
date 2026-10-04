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
import '../../library/import_export/import_track_matcher.dart';
import '../../library/import_export/playlist_import_export_service.dart';
import '../player_models.dart';
import '../player_providers.dart';

/// "Crear cola con IA" (Fase 7.F.2, simplificada en la ronda 5).
///
/// Ronda 5: "Mejorar cola" pasó a ser una acción rápida sin IA (radio de
/// Deezer, ver `improveQueueWithRecommendations`). Esta hoja queda solo para
/// pedir una cola por texto, y el resultado entra en la **cola manual**: es
/// algo que el usuario pidió explícitamente, como "Agregar a la cola".
void showAiCreateQueueSheet(BuildContext context, WidgetRef ref) {
  final isConnected = ref.read(isConnectedProvider).value ?? true;
  if (!isConnected) {
    AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
    return;
  }
  AppBottomSheet.show(
    context: context,
    title: 'Crear cola con IA',
    maxHeightFactor: 0.9,
    child: const _AiCreateQueueFlow(),
  );
}

enum _Step { form, callingAi, matching, preview, applying }

const List<int> _kCountOptions = [10, 25, 50];

/// Ideas de un toque para no arrancar con el campo vacío.
const List<String> _kPromptIdeas = [
  'Algo más movido',
  'Para concentrarme',
  'Clásicos que todos conocen',
  'Para relajarme',
];
const int _kDefaultCount = 25;
const int _kHardCountCap = 100; // D-5 / validate_request.ts MAX_REQUESTED_COUNT.create_queue

class _AiCreateQueueFlow extends ConsumerStatefulWidget {
  const _AiCreateQueueFlow();

  @override
  ConsumerState<_AiCreateQueueFlow> createState() => _AiCreateQueueFlowState();
}

class _AiCreateQueueFlowState extends ConsumerState<_AiCreateQueueFlow> {
  final _promptController = TextEditingController();

  late _Step _step;
  late bool _basedOnCurrent;
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
    // Ronda 5 (2.ª tanda): apagado por defecto. Encendido, la IA mezcla tu
    // pedido con lo que suena; si escuchas algo muy distinto a lo que pides
    // ("para relajarme" con metal sonando) el resultado puede salir raro, así
    // que es algo que se elige a propósito.
    _basedOnCurrent = false;
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

  /// "Lo que estoy escuchando" (ronda 5, 2.ª tanda): la canción actual, lo
  /// que pediste a mano y las siguientes 40 de la cola, como mucho 50. Antes
  /// viajaba la cola entera (hasta 1500 canciones de una playlist grande): la
  /// referencia se diluía en todo el contexto y costaba más tokens.
  List<Map<String, dynamic>> _buildQueueContext() {
    final state = ref.read(syncoraPlayerControllerProvider.notifier).state;
    final seen = <String>{};
    final tracks = <SyncoraTrack>[];
    void add(SyncoraTrack t) {
      if (tracks.length < 50 && seen.add(t.id)) tracks.add(t);
    }

    final current = state.currentTrack;
    if (current != null) add(current);
    state.manualQueue.forEach(add);
    state.autoQueue.take(40).forEach(add);
    return tracks.map((t) => {'id': t.id, 'title': t.title, 'artist': t.artist}).toList();
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

    if (prompt.isEmpty) {
      setState(() {
        _step = _Step.form;
        _formError = 'Escribe qué quieres escuchar o elige una de las ideas.';
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
        interleave: false,
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

    await _matchAndSettle(rawTracks, prompt: prompt, contextTracks: contextTracks);
  }

  /// Clave "título|artista" normalizada: la misma canción puede venir con
  /// otro id de Deezer (sencillo vs. álbum).
  static String _songKey(String title, String artist) =>
      '${ImportTrackMatcher.baseTitle(title)}|${ImportTrackMatcher.normalizeName(artist.split(RegExp(r'[;,]')).first)}';

  /// Lo que ya está en la cola o en la playlist que suena (ronda 4): la IA
  /// no debe sugerirlo otra vez.
  (Set<String>, Set<String>) _alreadyQueued() {
    final state = ref.read(syncoraPlayerControllerProvider.notifier).state;
    final ids = <String>{};
    final keys = <String>{};
    void add(SyncoraTrack t) {
      ids.add(t.id);
      keys.add(_songKey(t.title, t.artist));
    }

    final current = state.currentTrack;
    if (current != null) add(current);
    state.manualQueue.forEach(add);
    state.autoQueue.forEach(add);
    state.originalContextTracks.forEach(add);
    return (ids, keys);
  }

  List<DeezerTrack> _withoutRepeats(List<DeezerTrack> tracks, Set<String> ids, Set<String> keys) {
    final out = <DeezerTrack>[];
    for (final t in tracks) {
      final key = _songKey(t.title, t.artistName);
      if (ids.contains(t.id.toString()) || keys.contains(key)) continue;
      ids.add(t.id.toString());
      keys.add(key);
      out.add(t);
    }
    return out;
  }

  Future<void> _matchAndSettle(
    List<RawImportTrack> rawTracks, {
    String? prompt,
    List<Map<String, dynamic>>? contextTracks,
  }) async {
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

    // Ronda 4: fuera lo que ya está en la cola/playlist y las repetidas.
    // Ronda 5 (2.ª tanda): hasta 3 rondas de relleno. Con una sola, pedir 10
    // daba 5 y pedir 25 daba 18: además de las que Deezer no encuentra, se
    // descartan las que ya están en tu cola o en la playlist que suena (la IA
    // no las conoce si no le pasas contexto, y sugiere justo las conocidas).
    // Cada ronda le dice todo lo ya sugerido para que no lo repita.
    final (ids, keys) = _alreadyQueued();
    var fresh = _withoutRepeats(matched, ids, keys);
    final suggestedSoFar = <Map<String, dynamic>>[
      for (final r in rawTracks) {'title': r.title, 'artist': r.artist},
    ];
    for (var round = 0; round < 3 && fresh.length < _count; round++) {
      final missing = _count - fresh.length;
      setState(() => _matchCurrentName = 'Completando: faltan $missing canciones');
      try {
        final extra = await ref.read(aiAssistantServiceProvider).createQueue(
              prompt: prompt,
              // Lo ya sugerido viaja como contexto: el prompt del servidor
              // pide no repetir nada del contexto.
              contextTracks: [...?contextTracks, ...suggestedSoFar],
              interleave: false,
              count: _clampInt(missing * 2 + 3, 1, _kHardCountCap),
            );
        final extraRaw = PlaylistImportExportService.parseTrackSuggestions(extra['tracks']);
        if (extraRaw.isEmpty) break;
        suggestedSoFar.addAll([for (final r in extraRaw) {'title': r.title, 'artist': r.artist}]);
        final extraMatched = <DeezerTrack>[];
        await for (final _ in service.processImport(
          rawTracks: extraRaw,
          outMatched: extraMatched,
          outUnmatched: unmatched,
        )) {
          if (!mounted) return;
        }
        fresh = [...fresh, ..._withoutRepeats(extraMatched, ids, keys)];
      } catch (_) {
        break; // Sin más relleno: se muestra lo que hay.
      }
      if (!mounted) return;
    }

    final trimmed = PlaylistImportExportService.trimToCount(fresh, _count);

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
    ref.read(syncoraPlayerControllerProvider.notifier).addAllToQueue(syncoraTracks);

    if (!mounted) return;
    AppBottomSheet.pop(context);
    AppToast.show(context, message: '${syncoraTracks.length} canciones agregadas a la cola');
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
          '¿Qué quieres escuchar?',
          style: TextStyle(color: AppTheme.secondary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _promptController,
          maxLines: 3,
          minLines: 2,
          maxLength: 600,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(color: AppTheme.primary),
          decoration: InputDecoration(
            hintText: 'Ej: rock de los 2000 para manejar',
            hintStyle: const TextStyle(color: AppTheme.muted, fontSize: 13),
            filled: true,
            fillColor: AppTheme.surfaceHover,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            counterText: '',
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final idea in _kPromptIdeas)
              ActionChip(
                label: Text(idea, style: const TextStyle(color: AppTheme.primary, fontSize: 12)),
                backgroundColor: AppTheme.surfaceHover,
                side: BorderSide.none,
                shape: const StadiumBorder(),
                onPressed: () {
                  _promptController.text = idea;
                  _promptController.selection = TextSelection.collapsed(offset: idea.length);
                  if (_formError != null) setState(() => _formError = null);
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          value: _basedOnCurrent,
          onChanged: (v) => setState(() => _basedOnCurrent = v),
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeTrackColor: AppTheme.accent,
          title: const Text(
            'Parecido a lo que estoy escuchando',
            style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            'Usa la canción actual y las siguientes de tu cola como referencia. Tu texto siempre manda.',
            style: TextStyle(color: AppTheme.secondary, fontSize: 11.5),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Canciones',
                style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            for (final c in _kCountOptions) ...[
              const SizedBox(width: 6),
              SizedBox(width: 56, child: _choiceChip('$c', _count == c, () => setState(() => _count = c))),
            ],
          ],
        ),
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
                label: const Text('Crear cola', style: TextStyle(fontWeight: FontWeight.bold)),
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
    return Material(
      color: selected ? AppTheme.primary : AppTheme.surfaceHover,
      shape: StadiumBorder(side: BorderSide(color: selected ? AppTheme.primary : AppTheme.surfaceHover)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: selected ? AppTheme.background : AppTheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
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
                      : const Text(
                          'Agregar a la cola',
                          style: TextStyle(fontWeight: FontWeight.bold),
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
