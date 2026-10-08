import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
import '../../../core/widgets/ai_generation_steps.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/apis/lrclib_provider.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/services/ai_assistant_service.dart';
import '../../library/import_export/playlist_import_export_service.dart';
import '../../player/player_providers.dart';
import 'lyric_match.dart';

/// Fase 7.F.4 -- "Buscar canción por fragmento de letra". Entrada desde el
/// botón junto a "Popular" / "Búsqueda Profunda" en `search_screen.dart`.
void showAiLyricSearchSheet(BuildContext context, WidgetRef ref) {
  final isConnected = ref.read(isConnectedProvider).value ?? true;
  if (!isConnected) {
    AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
    return;
  }
  AppBottomSheet.show(
    context: context,
    title: 'Buscar por letra',
    maxHeightFactor: 0.9,
    child: const _AiLyricSearchFlow(),
  );
}

enum _Step { form, callingAi, matching, results }

class _AiLyricSearchFlow extends ConsumerStatefulWidget {
  const _AiLyricSearchFlow();

  @override
  ConsumerState<_AiLyricSearchFlow> createState() => _AiLyricSearchFlowState();
}

class _AiLyricSearchFlowState extends ConsumerState<_AiLyricSearchFlow> {
  final _lyricController = TextEditingController();

  _Step _step = _Step.form;
  bool _isSubmitting = false;
  String? _formError;

  int _matchCurrent = 0;
  int _matchTotal = 0;
  String _matchCurrentName = '';

  List<DeezerTrack> _results = const [];

  /// Ids de [_results] cuya letra real (LRCLib) contiene el fragmento. Van
  /// primero, bajo "La letra coincide".
  Set<int> _confirmedIds = const {};

  @override
  void dispose() {
    _lyricController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final isConnected = ref.read(isConnectedProvider).value ?? true;
    if (!isConnected) {
      AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
      return;
    }

    final fragment = _lyricController.text.trim();
    if (fragment.isEmpty) {
      setState(() => _formError = 'Pega un fragmento de la letra.');
      return;
    }
    setState(() {
      _formError = null;
      _isSubmitting = true;
      _step = _Step.callingAi;
    });

    final service = ref.read(aiAssistantServiceProvider);
    Map<String, dynamic> result;
    try {
      result = await service.lyricSearch(lyricFragment: fragment);
    } on AiAssistantException catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.form;
        _isSubmitting = false;
      });
      AppToast.show(context, message: e.message);
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _step = _Step.form;
        _isSubmitting = false;
      });
      AppToast.show(context, message: 'No se pudo contactar al asistente de IA. Revisa tu conexión e intenta de nuevo.');
      return;
    }

    final rawTracks = PlaylistImportExportService.parseTrackSuggestions(result['songs']);
    if (rawTracks.isEmpty) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _step = _Step.results;
        _isSubmitting = false;
      });
      return;
    }

    await _matchAndSettle(rawTracks, fragment);
  }

  Future<void> _matchAndSettle(List<RawImportTrack> rawTracks, String fragment) async {
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
      // Igual que 7.F.1/7.F.2: processImport ya cuenta los fallos por pista
      // como no-matcheadas, esto solo cubre un fallo catastrófico inesperado.
    }

    if (!mounted) return;

    // La misma canción puede salir dos veces (la IA la repite con otro
    // título, o dos sugerencias acaban en la misma versión del artista).
    final seen = <int>{};
    final unique = [for (final t in matched) if (seen.add(t.id)) t];

    setState(() => _matchCurrentName = 'Comprobando la letra de cada canción...');
    final confirmed = await _confirmWithLyrics(unique, fragment);

    if (!mounted) return;
    setState(() {
      // Estable: dentro de cada grupo se respeta el orden de la IA.
      _results = [
        ...unique.where((t) => confirmed.contains(t.id)),
        ...unique.where((t) => !confirmed.contains(t.id)),
      ];
      _confirmedIds = confirmed;
      _step = _Step.results;
      _isSubmitting = false;
    });
  }

  /// Busca la letra de cada candidato en LRCLib (en paralelo, la misma caché
  /// que usa el reproductor) y devuelve los que contienen el fragmento. Si
  /// LRCLib no tiene la letra o no responde, el candidato simplemente no se
  /// confirma: nunca se descarta por eso.
  Future<Set<int>> _confirmWithLyrics(List<DeezerTrack> tracks, String fragment) async {
    final lrclib = ref.read(lrcLibApiProvider);
    final results = await Future.wait(tracks.map((t) async {
      try {
        final lyrics = await lrclib.getLyrics(
          cacheKey: t.id.toString(),
          trackTitle: t.title,
          artistName: t.contributorsList.isNotEmpty ? t.contributorsList.first.name : t.artistName,
          durationSec: t.durationSec,
        );
        final text = lyrics?.plainLyrics ?? lyrics?.syncedLyrics ?? '';
        return LyricMatch.isConfirmed(fragment, text) ? t.id : null;
      } catch (_) {
        return null;
      }
    }));
    return {for (final id in results) ?id};
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _Step.form:
        return _buildForm();
      case _Step.callingAi:
        return const AiGeneratingIndicator(label: 'Buscando coincidencias...');
      case _Step.matching:
        return AiMatchingProgress(current: _matchCurrent, total: _matchTotal, currentTrackName: _matchCurrentName);
      case _Step.results:
        return _buildResults();
    }
  }

  Widget _buildForm() {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        const Text(
          'Pega el fragmento de letra que recuerdes',
          style: TextStyle(color: AppTheme.secondary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _lyricController,
          maxLines: 4,
          maxLength: 600,
          autofocus: true,
          style: const TextStyle(color: AppTheme.primary),
          decoration: InputDecoration(
            hintText: 'Ej: y si te vuelvo a ver, no sé qué voy a hacer',
            hintStyle: const TextStyle(color: AppTheme.muted, fontSize: 13),
            filled: true,
            fillColor: AppTheme.surfaceHover,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            counterStyle: const TextStyle(color: AppTheme.muted, fontSize: 11),
          ),
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
                label: const Text('Buscar con IA', style: TextStyle(fontWeight: FontWeight.bold)),
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

  Widget _buildResults() {
    if (_results.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(
            height: 180,
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'No identificamos ninguna canción con ese fragmento. Prueba con otro trozo de la letra.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.secondary, fontSize: 13),
                ),
              ),
            ),
          ),
          _searchAgainButton(),
        ],
      );
    }

    final syncoraTracks = _results.map((t) => t.toSyncoraTrack()).toList();
    final currentTrack = ref.watch(currentTrackProvider);
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final confirmedCount = _results.where((t) => _confirmedIds.contains(t.id)).length;

    Widget tile(int i) {
      final track = syncoraTracks[i];
      return TrackTile(
        track: track,
        isPlaying: currentTrack?.id == track.id,
        onTap: () => controller.setQueue(syncoraTracks, startIndex: i),
        onAddToQueue: () => controller.addToQueue(track),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            '${_results.length} posibles coincidencias',
            style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
          ),
        ),
        const Divider(color: AppTheme.surfaceHover, height: 1),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              if (confirmedCount > 0) ...[
                _sectionLabel('La letra coincide', highlighted: true),
                for (var i = 0; i < confirmedCount; i++) tile(i),
              ],
              if (confirmedCount < syncoraTracks.length) ...[
                if (confirmedCount > 0) _sectionLabel('Otras posibilidades'),
                for (var i = confirmedCount; i < syncoraTracks.length; i++) tile(i),
              ],
            ],
          ),
        ),
        _searchAgainButton(),
      ],
    );
  }

  Widget _sectionLabel(String text, {bool highlighted = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Row(
        children: [
          if (highlighted) ...[
            Icon(AppIcons.bold(SolarIcons.CheckCircle), size: 14, color: AppTheme.accent),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              color: highlighted ? AppTheme.primary : AppTheme.secondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  /// Vuelve al formulario con el fragmento escrito, para corregirlo o
  /// probar con otro trozo sin cerrar la hoja.
  Widget _searchAgainButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: OutlinedButton.icon(
        onPressed: () => setState(() {
          _step = _Step.form;
          _results = const [];
          _confirmedIds = const {};
        }),
        icon: Icon(AppIcons.broken(SolarIcons.Magnifer), size: 18),
        label: const Text('Buscar otra'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.primary,
          side: const BorderSide(color: AppTheme.surfaceHover),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}
