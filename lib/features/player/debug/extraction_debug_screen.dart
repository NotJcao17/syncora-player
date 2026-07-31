// TODO: Eliminar en Fase 3
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
    }
  }

  @override
  void dispose() {
    _videoIdController.dispose();
    _justAudioPlayer?.dispose();
    _mediaKitPlayer?.dispose();
    super.dispose();
  }

  void _log(String message) {
    setState(() {
      _logs.insert(
          0, '[${DateTime.now().toString().split('.').first}] $message');
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
            await _justAudioPlayer?.setUrl(
              streamUrl,
              headers: headers,
            );
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
    } catch (e) {
      _log('Excepción inesperada: $e');
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
              'Logs de Extracción y Reproducción:',
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
                          fontSize: 12,
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
}
