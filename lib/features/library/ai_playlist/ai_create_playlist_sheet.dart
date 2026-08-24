import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
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

/// Fase 7.F.1 -- "Crear playlist con IA". Entrada desde el botón con ícono
/// `StarsMinimalistic` en Biblioteca (D-14), junto a "crear playlist".
///
/// Todo el flujo (formulario -> generación -> matching contra Deezer ->
/// vista previa editable -> guardar) vive en un solo `AppBottomSheet` que
/// cambia de contenido según el paso actual, en vez de encadenar varias
/// hojas -- más simple de navegar y evita perder el estado del formulario
/// entre pasos.
void showAiCreatePlaylistSheet(BuildContext context, WidgetRef ref) {
  final isConnected = ref.read(isConnectedProvider).value ?? true;
  if (!isConnected) {
    AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
    return;
  }
  AppBottomSheet.show(
    context: context,
    title: 'Crear playlist con IA',
    maxHeightFactor: 0.9,
    child: const _AiCreatePlaylistFlow(),
  );
}

enum _Step { form, callingAi, matching, preview, saving }

const List<int> _kCountPresets = [25, 50, 100, 200];
const int _kHardCountCap = 300; // D-5 / validate_request.ts MAX_REQUESTED_COUNT.create_playlist

class _AiCreatePlaylistFlow extends ConsumerStatefulWidget {
  const _AiCreatePlaylistFlow();

  @override
  ConsumerState<_AiCreatePlaylistFlow> createState() => _AiCreatePlaylistFlowState();
}

class _AiCreatePlaylistFlowState extends ConsumerState<_AiCreatePlaylistFlow> {
  final _promptController = TextEditingController();
  final _maxPerArtistController = TextEditingController();
  final _genreController = TextEditingController();
  final _moodController = TextEditingController();
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _refineController = TextEditingController();

  _Step _step = _Step.form;
  bool _paramsExpanded = false;
  int? _countPreset;
  int? _selectedReferencePlaylistId;
  double _familiarity = 0.5;
  double _popularity = 0.5;
  String? _formError;
  bool _refinePanelOpen = false;

  // Protege la ventana entre tocar "Crear con IA" y que `_generate` recién
  // arranque -- `_loadReferenceTracks` (D-11) hace un `await` a la DB local
  // ANTES de eso, y en ese hueco el botón seguía habilitado: un doble-tap
  // disparaba dos `_generate` concurrentes cuyas respuestas se pisaban entre
  // sí sin ningún orden garantizado.
  bool _isSubmitting = false;

  // Fijados en el momento del submit (D-5): se re-usan también en "afinar
  // con IA" para que los topes numéricos elegidos por el usuario sigan
  // aplicando a las revisiones, no solo a la primera generación.
  int? _requestedExactCount;
  int? _maxPerArtist;

  // Progreso de matching (reusa el tipo `ImportProgress` del importador
  // CSV/TXT, mismo patrón visual que ese flujo).
  int _matchCurrent = 0;
  int _matchTotal = 0;
  String _matchCurrentName = '';

  // Resultado de la generación más reciente ya matcheada contra Deezer.
  List<DeezerTrack> _allMatched = const [];
  final Set<int> _excludedTrackIds = {};
  List<RawImportTrack> _unmatched = const [];

  // D-11 / selector de playlist de referencia -- creado una sola vez (no
  // inline en el build de `_buildReferencePlaylistPicker`): un `Stream`
  // nuevo en cada rebuild hace que `StreamBuilder` cancele y resuscriba en
  // cada frame (cada slider/chip/setState del panel de parámetros dispara
  // uno), dejando temporizadores de limpieza de Drift pendientes que
  // rompen los tests de widget y generan streams de la base local sin
  // necesidad en producción.
  late final Stream<List<Playlist>> _referencePlaylistsStream =
      ref.read(playlistDaoProvider).watchAllPlaylists();

  @override
  void dispose() {
    _promptController.dispose();
    _maxPerArtistController.dispose();
    _genreController.dispose();
    _moodController.dispose();
    _nameController.dispose();
    _descController.dispose();
    _refineController.dispose();
    super.dispose();
  }

  List<DeezerTrack> get _includedTracks =>
      _allMatched.where((t) => !_excludedTrackIds.contains(t.id)).toList();

  // El panel puede estar expandido sin que el usuario haya tocado nada en él
  // (los sliders arrancan en 0.5 neutral) -- exigir solo "panel expandido"
  // dejaba pasar un submit sin texto y sin ningún parámetro real elegido,
  // pese a que el mensaje de validación promete "elige alguno".
  bool get _hasAnyParamSet =>
      _countPreset != null ||
      _maxPerArtistController.text.trim().isNotEmpty ||
      _genreController.text.trim().isNotEmpty ||
      _moodController.text.trim().isNotEmpty ||
      _selectedReferencePlaylistId != null ||
      _familiarity != 0.5 ||
      _popularity != 0.5;

  int _clampInt(int value, int min, int max) => value < min ? min : (value > max ? max : value);

  Map<String, dynamic> _buildParams({bool isRefinement = false}) {
    final params = <String, dynamic>{};
    if (isRefinement) {
      params['isRefinement'] = true;
      return params;
    }
    if (!_paramsExpanded) return params;
    final genre = _genreController.text.trim();
    final mood = _moodController.text.trim();
    if (genre.isNotEmpty) params['genre'] = genre;
    if (mood.isNotEmpty) params['mood'] = mood;
    params['familiarity'] = _familiarity;
    params['popularity'] = _popularity;
    return params;
  }

  Future<List<Map<String, dynamic>>> _loadReferenceTracks(int playlistId) async {
    final dao = ref.read(playlistDaoProvider);
    final tracks = await dao.getTracksOrdered(playlistId);
    // Tope de seguridad del lado del cliente -- el servidor ya acepta hasta
    // 3000 (`MAX_CONTEXT_ITEMS`), esto solo evita payloads absurdos para
    // bibliotecas gigantes sin necesidad real.
    final capped = tracks.length > 500 ? tracks.sublist(0, 500) : tracks;
    return capped
        .map((t) => {
              'id': t.trackId.toString(),
              'title': t.title,
              'artist': t.artistName,
            })
        .toList();
  }

  List<DeezerTrack> _applyMaxPerArtist(List<DeezerTrack> tracks, int? maxPerArtist) {
    if (maxPerArtist == null || maxPerArtist <= 0) return tracks;
    final counts = <int, int>{};
    final result = <DeezerTrack>[];
    for (final t in tracks) {
      final c = counts[t.artistId] ?? 0;
      if (c < maxPerArtist) {
        result.add(t);
        counts[t.artistId] = c + 1;
      }
    }
    return result;
  }

  int? _extractAddCount(String text) {
    final clean = text.trim().toLowerCase();
    final plusMatch = RegExp(r'^\s*\+\s*(\d+)').firstMatch(clean);
    if (plusMatch != null) return int.tryParse(plusMatch.group(1)!);

    final addMatch = RegExp(r'(?:agrega|añade|anade|suma|adiciona|pon|inserta)\s+(\d+)').firstMatch(clean);
    if (addMatch != null) return int.tryParse(addMatch.group(1)!);

    final moreMatch = RegExp(r'(\d+)\s+(?:más|mas|canciones\s+más|canciones\s+mas|temas\s+más|adicionales)').firstMatch(clean);
    if (moreMatch != null) return int.tryParse(moreMatch.group(1)!);

    final isAddIntent = RegExp(r'\b(agrega|agregar|añade|anade|añadir|anadir|sumar|suma|más\s+canciones|mas\s+canciones)\b').hasMatch(clean);
    if (isAddIntent) {
      return 5;
    }
    return null;
  }

  Future<void> _submitForm() async {
    if (_isSubmitting) return;
    final isConnected = ref.read(isConnectedProvider).value ?? true;
    if (!isConnected) {
      AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
      return;
    }

    final prompt = _promptController.text.trim();
    if (prompt.isEmpty && !(_paramsExpanded && _hasAnyParamSet)) {
      setState(() => _formError = 'Escribe una descripción o abre los parámetros y elige alguno.');
      return;
    }
    setState(() {
      _formError = null;
      _isSubmitting = true;
    });

    try {
      _requestedExactCount = _countPreset != null ? _clampInt(_countPreset!, 1, _kHardCountCap) : null;
      final maxPerArtistText = _maxPerArtistController.text.trim();
      final parsedMax = int.tryParse(maxPerArtistText);
      _maxPerArtist = (parsedMax != null && parsedMax > 0) ? parsedMax : null;

      int? askCount;
      if (_requestedExactCount != null) {
        askCount = _clampInt((_requestedExactCount! * 1.3).round(), 1, _kHardCountCap);
      }

      List<Map<String, dynamic>>? contextTracks;
      if (_selectedReferencePlaylistId != null) {
        try {
          contextTracks = await _loadReferenceTracks(_selectedReferencePlaylistId!);
        } catch (_) {
          contextTracks = null;
        }
      }

      final params = _buildParams();
      await _generate(
        prompt: prompt.isEmpty ? null : prompt,
        params: params.isEmpty ? null : params,
        count: askCount,
        contextTracks: contextTracks,
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _refine() async {
    final isConnected = ref.read(isConnectedProvider).value ?? true;
    if (!isConnected) {
      AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
      return;
    }

    final instruction = _refineController.text.trim();
    if (instruction.isEmpty) {
      AppToast.show(context, message: 'Escribe qué quieres ajustar antes de afinar.');
      return;
    }

    final addCount = _extractAddCount(instruction);
    _refineController.clear();
    setState(() => _refinePanelOpen = false);

    if (addCount != null && addCount > 0) {
      await _refineAdd(instruction, addCount);
      return;
    }

    final contextTracks = _includedTracks
        .map((t) => {
              'id': t.id.toString(),
              'title': t.title,
              'artist': t.artistName,
            })
        .toList();

    int? askCount;
    if (_requestedExactCount != null) {
      askCount = _clampInt((_requestedExactCount! * 1.3).round(), 1, _kHardCountCap);
    }

    await _generate(
      prompt: instruction,
      params: _buildParams(isRefinement: true),
      count: askCount,
      contextTracks: contextTracks,
    );
  }

  Future<void> _refineAdd(String instruction, int addCount) async {
    setState(() => _step = _Step.callingAi);
    final contextTracks = _includedTracks
        .map((t) => {
              'id': t.id.toString(),
              'title': t.title,
              'artist': t.artistName,
            })
        .toList();

    final askCount = _clampInt((addCount * 1.3).round(), 1, _kHardCountCap);
    final service = ref.read(aiAssistantServiceProvider);
    Map<String, dynamic> result;
    try {
      result = await service.modifyPlaylistAdd(
        prompt: instruction,
        contextTracks: contextTracks.isEmpty ? null : contextTracks,
        count: askCount,
      );
    } on AiAssistantException catch (e) {
      if (!mounted) return;
      setState(() => _step = _Step.preview);
      AppToast.show(context, message: e.message);
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _step = _Step.preview);
      AppToast.show(context, message: 'No se pudo contactar al asistente de IA. Revisa tu conexión e intenta de nuevo.');
      return;
    }

    final rawTracks = PlaylistImportExportService.parseTrackSuggestions(result['tracks']);
    if (rawTracks.isEmpty) {
      if (!mounted) return;
      setState(() => _step = _Step.preview);
      AppToast.show(context, message: 'La IA no devolvió canciones adicionales.');
      return;
    }

    await _matchAndAppend(rawTracks, addCount);
  }

  Future<void> _matchAndAppend(List<RawImportTrack> rawTracks, int addCount) async {
    if (!mounted) return;
    final deezerApi = ref.read(deezerApiProvider);
    final service = PlaylistImportExportService(deezerApi);
    final matched = <DeezerTrack>[];
    final unmatched = <RawImportTrack>[];

    final displayTotal = addCount;
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
    final filtered = PlaylistImportExportService.trimToCount(matched, addCount);
    final existingIds = _allMatched.map((t) => t.id).toSet();
    final newUnique = filtered.where((t) => !existingIds.contains(t.id)).toList();

    setState(() {
      _allMatched = [..._allMatched, ...newUnique];
      _unmatched = [..._unmatched, ...unmatched];
      _step = _Step.preview;
    });

    if (newUnique.isEmpty) {
      AppToast.show(context, message: 'No se encontraron canciones nuevas para añadir.');
    } else {
      AppToast.show(context, message: '${newUnique.length} canciones añadidas a la playlist');
    }
  }

  Future<void> _generate({
    String? prompt,
    Map<String, dynamic>? params,
    int? count,
    List<Map<String, dynamic>>? contextTracks,
  }) async {
    final hadPreviousDraft = _allMatched.isNotEmpty;
    setState(() => _step = _Step.callingAi);

    final service = ref.read(aiAssistantServiceProvider);
    Map<String, dynamic> result;
    try {
      result = await service.createPlaylist(
        prompt: prompt,
        params: params,
        count: count,
        contextTracks: contextTracks,
      );
    } on AiAssistantException catch (e) {
      if (!mounted) return;
      setState(() => _step = hadPreviousDraft ? _Step.preview : _Step.form);
      AppToast.show(context, message: e.message);
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _step = hadPreviousDraft ? _Step.preview : _Step.form);
      AppToast.show(context, message: 'No se pudo contactar al asistente de IA. Revisa tu conexión e intenta de nuevo.');
      return;
    }

    final name = (result['playlistName'] as String?)?.trim();
    final desc = (result['description'] as String?)?.trim();
    final rawTracks = PlaylistImportExportService.parseTrackSuggestions(result['tracks']);

    if (name != null && name.isNotEmpty) _nameController.text = name;
    if (desc != null) _descController.text = desc;

    if (rawTracks.isEmpty) {
      if (!mounted) return;
      setState(() => _step = hadPreviousDraft ? _Step.preview : _Step.form);
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

    final displayTotal = _requestedExactCount ?? rawTracks.length;
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
    } catch (_) {
    }

    if (!mounted) return;

    var filtered = _applyMaxPerArtist(matched, _maxPerArtist);
    filtered = PlaylistImportExportService.trimToCount(filtered, _requestedExactCount);

    setState(() {
      _allMatched = filtered;
      _excludedTrackIds.clear();
      _unmatched = unmatched;
      _step = _Step.preview;
    });

    if (filtered.isEmpty) {
      AppToast.show(context, message: 'Ninguna de las sugerencias de la IA se encontró en Deezer.');
    }
  }

  Future<void> _save() async {
    final included = _includedTracks;
    if (included.isEmpty) {
      AppToast.show(context, message: 'No hay canciones seleccionadas para guardar.');
      return;
    }
    setState(() => _step = _Step.saving);
    try {
      final service = PlaylistImportExportService(ref.read(deezerApiProvider));
      final title = _nameController.text.trim().isEmpty ? 'Playlist con IA' : _nameController.text.trim();
      final description = _descController.text.trim();
      await service.createPlaylistWithMatchedTracks(
        title: title,
        description: description.isEmpty ? null : description,
        matchedTracks: included,
        dao: ref.read(playlistDaoProvider),
        deezerApi: ref.read(deezerApiProvider),
        supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
      );
      if (!mounted) return;
      AppBottomSheet.pop(context);
      AppToast.show(context, message: 'Playlist creada con IA (${included.length} canciones)');
    } catch (_) {
      if (!mounted) return;
      setState(() => _step = _Step.preview);
      AppToast.show(context, message: 'No se pudo guardar la playlist. Intenta de nuevo.');
    }
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
        return _buildGenerating();
      case _Step.matching:
        return _buildMatching();
      case _Step.preview:
      case _Step.saving:
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
          'Describe la playlist que quieres',
          style: TextStyle(color: AppTheme.secondary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _promptController,
          maxLines: 3,
          maxLength: 600,
          style: const TextStyle(color: AppTheme.primary),
          decoration: InputDecoration(
            hintText: 'Ej: música energética para entrenar, con rock y pop de los 2010s',
            hintStyle: const TextStyle(color: AppTheme.muted, fontSize: 13),
            filled: true,
            fillColor: AppTheme.surfaceHover,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            counterStyle: const TextStyle(color: AppTheme.muted, fontSize: 11),
          ),
        ),
        const SizedBox(height: 12),
        _buildParamsHeader(),
        if (_paramsExpanded) _buildParamsPanel(),
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
                onPressed: _isSubmitting ? null : _submitForm,
                icon: Icon(AppIcons.broken(SolarIcons.StarsMinimalistic), size: 18),
                label: const Text('Crear con IA', style: TextStyle(fontWeight: FontWeight.bold)),
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

  Widget _buildParamsHeader() {
    return InkWell(
      onTap: () => setState(() => _paramsExpanded = !_paramsExpanded),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(AppIcons.broken(SolarIcons.Tuning), color: AppTheme.secondary, size: 18),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Parámetros (opcional)',
                style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ),
            Icon(
              AppIcons.broken(_paramsExpanded ? SolarIcons.AltArrowUp : SolarIcons.AltArrowDown),
              color: AppTheme.secondary,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildParamsPanel() {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Cantidad de canciones', style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: _kCountPresets.map((preset) {
              final selected = _countPreset == preset;
              return ChoiceChip(
                label: Text('$preset'),
                selected: selected,
                onSelected: (val) => setState(() => _countPreset = val ? preset : null),
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
            }).toList(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _maxPerArtistController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: AppTheme.primary),
            decoration: _fieldDecoration('Máximo de canciones por artista (opcional)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _genreController,
            style: const TextStyle(color: AppTheme.primary),
            decoration: _fieldDecoration('Género (opcional)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _moodController,
            style: const TextStyle(color: AppTheme.primary),
            decoration: _fieldDecoration('Mood / estado de ánimo (opcional)'),
          ),
          const SizedBox(height: 16),
          _buildSlider(
            label: 'Conocidas ←→ Descubrimiento',
            value: _familiarity,
            onChanged: (v) => setState(() => _familiarity = v),
          ),
          const SizedBox(height: 8),
          _buildSlider(
            label: 'Nicho ←→ Popular',
            value: _popularity,
            onChanged: (v) => setState(() => _popularity = v),
          ),
          const SizedBox(height: 16),
          const Text('Basada en una playlist mía (opcional)', style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _buildReferencePlaylistPicker(),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppTheme.muted, fontSize: 13),
      filled: true,
      fillColor: AppTheme.surfaceHover,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    );
  }

  Widget _buildSlider({required String label, required double value, required ValueChanged<double> onChanged}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600)),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(activeTrackColor: AppTheme.primary, thumbColor: AppTheme.primary),
          child: Slider(value: value, onChanged: onChanged),
        ),
      ],
    );
  }

  Widget _buildReferencePlaylistPicker() {
    // D-11: solo playlists propias -- Drift local solo contiene las
    // playlists del usuario actual (caché por dispositivo/cuenta), así que
    // esta lista nunca puede incluir playlists públicas de terceros.
    return StreamBuilder<List<Playlist>>(
      stream: _referencePlaylistsStream,
      builder: (context, snapshot) {
        final playlists = snapshot.data ?? const [];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(color: AppTheme.surfaceHover, borderRadius: BorderRadius.circular(12)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int?>(
              isExpanded: true,
              value: _selectedReferencePlaylistId,
              dropdownColor: AppTheme.surface,
              style: const TextStyle(color: AppTheme.primary, fontSize: 13),
              hint: const Text('Ninguna', style: TextStyle(color: AppTheme.muted, fontSize: 13)),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('Ninguna')),
                ...playlists.map((p) => DropdownMenuItem<int?>(value: p.id, child: Text(p.title, overflow: TextOverflow.ellipsis))),
              ],
              onChanged: (val) => setState(() => _selectedReferencePlaylistId = val),
            ),
          ),
        );
      },
    );
  }

  // --- Paso 2: generando con IA -------------------------------------------

  // D-14: variante bold del ícono mientras la generación está en curso
  // (compartido con 7.F.2, ver `core/widgets/ai_generation_steps.dart`).
  Widget _buildGenerating() => const AiGeneratingIndicator();

  // --- Paso 3: matching contra Deezer -------------------------------------

  Widget _buildMatching() => AiMatchingProgress(
        current: _matchCurrent,
        total: _matchTotal,
        currentTrackName: _matchCurrentName,
      );

  // --- Paso 4: vista previa ------------------------------------------------

  Widget _buildPreview() {
    final included = _includedTracks;
    final isSaving = _step == _Step.saving;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 16),
                decoration: _fieldDecoration('Nombre de la playlist'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _descController,
                maxLines: 2,
                style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                decoration: _fieldDecoration('Descripción (opcional)'),
              ),
              const SizedBox(height: 8),
              Text(
                '${included.length} canciones seleccionadas'
                '${_unmatched.isNotEmpty ? ' · ${_unmatched.length} no encontradas' : ''}',
                style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
              ),
            ],
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
        if (_refinePanelOpen) _buildRefinePanel(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isSaving ? null : () => setState(() => _refinePanelOpen = !_refinePanelOpen),
                  icon: Icon(AppIcons.broken(SolarIcons.StarsMinimalistic), size: 16),
                  label: const Text('Afinar con IA'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: const BorderSide(color: AppTheme.surfaceHover),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: isSaving || included.isEmpty ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: AppTheme.background,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.background),
                        )
                      : const Text('Guardar playlist', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRefinePanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Describe el ajuste (esto sí gasta una petición de IA)',
            style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _refineController,
            maxLines: 2,
            style: const TextStyle(color: AppTheme.primary, fontSize: 13),
            decoration: _fieldDecoration('Ej: menos canciones lentas, más de los 2000s'),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: _refine,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: AppTheme.background,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Enviar ajuste', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }
}
