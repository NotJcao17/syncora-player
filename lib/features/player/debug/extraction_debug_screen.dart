// TODO: Eliminar en Fase 3
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:media_kit/media_kit.dart' as mk;

import '../../../core/extraction/extraction_provider.dart';
import '../../../core/extraction/models/extraction_result.dart';
import '../../../core/theme/app_theme.dart';

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
  bool _isLoading = false;
  bool _isPlaying = false;

  ja.AudioPlayer? _justAudioPlayer;
  mk.Player? _mediaKitPlayer;
  StreamSubscription<String>? _logSubscription;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isWindows) {
      _mediaKitPlayer = mk.Player();
      _mediaKitPlayer!.stream.playing.listen((playing) {
        if (mounted) setState(() => _isPlaying = playing);
      });
    } else {
      _justAudioPlayer = ja.AudioPlayer();
      _justAudioPlayer!.playerStateStream.listen((state) {
        if (mounted) setState(() => _isPlaying = state.playing);
      });
      // Escuchar errores de just_audio para diagnóstico
      _justAudioPlayer!.playbackEventStream.listen(
        (_) {},
        onError: (Object e, StackTrace st) {
          if (mounted) _log('[JA Error] $e');
        },
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final service = ref.read(extractionServiceProvider);
      _logSubscription = service.onLogMessage.listen((msg) {
        if (mounted) {
          _log(msg);
        }
      });
    });
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _videoIdController.dispose();
    _justAudioPlayer?.dispose();
    _mediaKitPlayer?.dispose();
    super.dispose();
  }

  void _log(String message) {
    setState(() {
      _logs.insert(
          0, '[${DateTime.now().toString().split('.').first.split(' ').last}] $message');
    });
  }

  Future<void> _extractAndPlay() async {
    final videoId = _videoIdController.text.trim();
    if (videoId.isEmpty) return;

    setState(() => _isLoading = true);
    _log('Iniciando extracción para videoId: $videoId...');

    final service = ref.read(extractionServiceProvider);

    try {
      final result = await service.extractUrl(videoId);

      if (!mounted) return;

      switch (result) {
        case ExtractionSuccess(:final streamUrl, :final headers):
          _log(
              'URL obtenida con éxito: ${streamUrl.substring(0, streamUrl.length > 50 ? 50 : streamUrl.length)}...');
          _log('Headers aplicados (Pitfall #13): $headers');
          _log('Iniciando reproducción nativa...');

          if (!kIsWeb && Platform.isWindows) {
            await _mediaKitPlayer?.open(
              mk.Media(streamUrl, httpHeaders: headers),
            );
          } else {
            // En Android, ExoPlayer requiere los headers exactos que usó
            // el cliente ANDROID para firmar la petición.
            // Usar AudioSource.uri con los headers permite que ExoPlayer
            // los envíe correctamente sin duplicarlos.
            _log('URL (primeros 80 chars): ${streamUrl.substring(0, streamUrl.length > 80 ? 80 : streamUrl.length)}...');
            final audioSource = ja.AudioSource.uri(
              Uri.parse(streamUrl),
              headers: headers,
            );
            await _justAudioPlayer?.setAudioSource(audioSource);
            await _justAudioPlayer?.play();
          }
          _log('Reproduciendo audio correctamente.');
          break;

        case ExtractionFailure(:final error, :final message):
          _log('Error de extracción: $error');
          if (message != null) _log('Detalle: $message');
          _log('Reproductor pausado por seguridad (Guard 403).');
          break;
      }
    } catch (e, st) {
      if (e is PlatformException) {
        _log('Error nativo Android: code=${e.code}, msg=${e.message}');
        if (e.details != null) _log('Detalles: ${e.details}');
      }
      _log('Excepción inesperada: $e');
      if (kDebugMode) debugPrint('StackTrace: $st');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _togglePlayPause() async {
    if (!kIsWeb && Platform.isWindows) {
      await _mediaKitPlayer?.playOrPause();
    } else {
      if (_isPlaying) {
        await _justAudioPlayer?.pause();
      } else {
        await _justAudioPlayer?.play();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: Text(
          'Debug Extractor (Fase 1)',
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
            TextField(
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
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('Pruebas: ', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  _buildPresetChip('Viva La Vida', 'dvgZkm1xWPE'),
                  _buildPresetChip('Dembow', 'kQKGI24aydk'),
                  _buildPresetChip('Uptown Funk', 'OPf0YbXqDm0'),
                  _buildPresetChip('Vienna', '3jL4S4X97sQ'),
                  _buildPresetChip('Rick Astley', 'dQw4w9WgXcQ'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _extractAndPlay,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Extraer y Reproducir'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _togglePlayPause,
                  icon: Icon(
                    _isPlaying ? Icons.pause_circle : Icons.play_circle,
                    size: 40,
                    color: AppTheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Logs de Extracción y Reproducción (en vivo):',
              style: GoogleFonts.plusJakartaSans(
                color: AppTheme.secondary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Text(
                        _logs[index],
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
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

  Widget _buildPresetChip(String label, String videoId) {
    return Padding(
      padding: const EdgeInsets.only(right: 6.0),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 11, color: Colors.white)),
        backgroundColor: AppTheme.surface,
        side: BorderSide(color: AppTheme.secondary.withValues(alpha: 0.3)),
        onPressed: () {
          setState(() {
            _videoIdController.text = videoId;
          });
          _extractAndPlay();
        },
      ),
    );
  }
}
