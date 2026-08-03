// TODO: Eliminar en Fase 3
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/extraction/extraction_provider.dart';
import '../../../core/extraction/models/extraction_result.dart';
import '../../../core/theme/app_theme.dart';
import '../audio_engine/audio_engine_state.dart';
import '../player_models.dart';
import '../player_providers.dart';

class ExtractionDebugScreen extends ConsumerStatefulWidget {
  const ExtractionDebugScreen({super.key});

  @override
  ConsumerState<ExtractionDebugScreen> createState() =>
      _ExtractionDebugScreenState();
}

class _ExtractionDebugScreenState
    extends ConsumerState<ExtractionDebugScreen> {
  final _videoIdController = TextEditingController(text: 'dQw4w9WgXcQ');
  final List<String> _logs = [];
  StreamSubscription<String>? _extractionLogSub;
  StreamSubscription<String>? _controllerLogSub;

  final List<SyncoraTrack> _testQueue = const [
    SyncoraTrack(
      id: 'dQw4w9WgXcQ',
      title: 'Never Gonna Give You Up',
      artist: 'Rick Astley',
    ),
    SyncoraTrack(
      id: 'dvgZkm1xWPE',
      title: 'Viva La Vida',
      artist: 'Coldplay',
    ),
    SyncoraTrack(
      id: 'OPf0YbXqDm0',
      title: 'Uptown Funk',
      artist: 'Mark Ronson ft. Bruno Mars',
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final extractionService = ref.read(extractionServiceProvider);
      _extractionLogSub = extractionService.onLogMessage.listen(_log);

      final controller = ref.read(syncoraPlayerControllerProvider);
      _controllerLogSub = controller.onLogMessage.listen(_log);
    });
  }

  @override
  void dispose() {
    _extractionLogSub?.cancel();
    _controllerLogSub?.cancel();
    _videoIdController.dispose();
    super.dispose();
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(
        0,
        '[${DateTime.now().toString().split('.').first.split(' ').last}] $message',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(syncoraPlayerControllerProvider);
    final state = controller.state;
    final engine = state.engine;
    final currentTrack = state.currentTrack;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: Text(
          'Debug Player (Fase 2)',
          style: GoogleFonts.plusJakartaSans(color: AppTheme.primary),
        ),
        actions: [
          IconButton(
            tooltip: 'Reiniciar Isolate / Motor JS',
            icon: const Icon(Icons.refresh, color: Colors.orangeAccent),
            onPressed: () {
              ref.read(extractionServiceProvider).resetEngine();
              _log('Solicitado reinicio del motor JS...');
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Banner de error 403
            if (state.lastError == ExtractionError.rateLimited) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.redAccent),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Error 403 — reproductor pausado por guard de seguridad.',
                        style: GoogleFonts.plusJakartaSans(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => controller.clearError(),
                      child: const Text('Descartar', style: TextStyle(color: Colors.white70)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Input manual de Video ID
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _videoIdController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'YouTube Video ID',
                      labelStyle: TextStyle(color: AppTheme.secondary),
                      filled: true,
                      fillColor: AppTheme.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    final id = _videoIdController.text.trim();
                    if (id.isEmpty) return;
                    final track = SyncoraTrack.fromVideoId(videoId: id);
                    controller.setQueue([track]);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                  ),
                  child: const Text('Play ID'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Botón cargar cola de prueba
            ElevatedButton.icon(
              onPressed: () => controller.setQueue(_testQueue),
              icon: const Icon(Icons.playlist_play),
              label: const Text('Cargar Cola de Prueba (3 Pistas)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.surface,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),

            // Tarjeta de pista activa e indicadores
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    currentTrack != null
                        ? '${currentTrack.title} — ${currentTrack.artist}'
                        : 'Sin pista en reproducción',
                    style: GoogleFonts.plusJakartaSans(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Estado: ${_formatProcessingState(engine.processingState)} | ${engine.playing ? "Playing" : "Paused"}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      Text(
                        '${_formatDuration(engine.position)} / ${_formatDuration(engine.duration)}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Controles de reproducción
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Shuffle',
                  icon: Icon(
                    Icons.shuffle,
                    color: state.shuffle ? Colors.greenAccent : Colors.white54,
                  ),
                  onPressed: () => controller.setShuffle(!state.shuffle),
                ),
                IconButton(
                  tooltip: 'Anterior',
                  icon: const Icon(Icons.skip_previous, color: Colors.white),
                  onPressed: () => controller.skipToPrevious(),
                ),
                IconButton(
                  tooltip: engine.playing ? 'Pausar' : 'Reproducir',
                  iconSize: 44,
                  icon: Icon(
                    engine.playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    color: AppTheme.primary,
                  ),
                  onPressed: () {
                    if (engine.playing) {
                      controller.pause();
                    } else {
                      controller.play();
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Siguiente',
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                  onPressed: () => controller.skipToNext(),
                ),
                IconButton(
                  tooltip: 'Repetir (${state.repeatMode.name})',
                  icon: Icon(
                    state.repeatMode == SyncoraRepeatMode.one
                        ? Icons.repeat_one
                        : Icons.repeat,
                    color: state.repeatMode != SyncoraRepeatMode.off
                        ? Colors.greenAccent
                        : Colors.white54,
                  ),
                  onPressed: () => controller.cycleRepeatMode(),
                ),
                IconButton(
                  tooltip: 'Skip Silence (${state.skipSilence ? "ON" : "OFF"})',
                  icon: Icon(
                    Icons.graphic_eq,
                    color: state.skipSilence ? Colors.greenAccent : Colors.white54,
                  ),
                  onPressed: () => controller.setSkipSilence(!state.skipSilence),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Lista de la cola actual
            if (state.queue.isNotEmpty) ...[
              Text(
                'Cola de reproducción (${state.queue.length} pistas):',
                style: GoogleFonts.plusJakartaSans(
                  color: AppTheme.secondary,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 90,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: state.queue.length,
                  itemBuilder: (context, index) {
                    final track = state.queue[index];
                    final isCurrent = index == state.currentIndex;
                    return GestureDetector(
                      onTap: () => controller.playIndex(index),
                      child: Container(
                        width: 140,
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? Colors.blueAccent.withValues(alpha: 0.3)
                              : AppTheme.surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isCurrent ? Colors.blueAccent : Colors.transparent,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              track.title,
                              style: TextStyle(
                                color: isCurrent ? Colors.white : Colors.white70,
                                fontWeight:
                                    isCurrent ? FontWeight.bold : FontWeight.normal,
                                fontSize: 11,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              track.artist,
                              style: const TextStyle(color: Colors.white38, fontSize: 10),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],

            Text(
              'Logs en vivo:',
              style: GoogleFonts.plusJakartaSans(
                color: AppTheme.secondary,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (context, index) {
                    return Text(
                      _logs[index],
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatProcessingState(AudioProcessingState state) {
    return state.name;
  }

  String _formatDuration(Duration d) {
    final mins = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }
}
