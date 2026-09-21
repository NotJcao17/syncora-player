import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../stats_models.dart';
import '../stats_providers.dart';

/// Wrapped: tarjetas tipo *stories*, una por dato, compartibles como imagen.
///
/// Rediseño respecto a la versión anterior, que eran cinco rectángulos de
/// texto plano sobre fondo gris y solo cubrían el año. Ahora: formato
/// vertical 9:16 pensado para compartir en redes, cada tarjeta con su propia
/// pareja de colores, portadas reales de artistas y canciones, barra de
/// progreso arriba como en cualquier app de stories, y **el periodo lo elige
/// el usuario** en el dashboard en vez de estar fijo al año.
class WrappedScreen extends ConsumerStatefulWidget {
  final StatsPeriod period;

  const WrappedScreen({super.key, required this.period});

  @override
  ConsumerState<WrappedScreen> createState() => _WrappedScreenState();
}

class _WrappedScreenState extends ConsumerState<WrappedScreen> {
  final PageController _pageController = PageController();
  final Map<int, GlobalKey> _cardKeys = {};
  int _index = 0;
  bool _isSharing = false;

  GlobalKey _keyFor(int i) => _cardKeys.putIfAbsent(i, () => GlobalKey());

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Rasteriza la tarjeta visible y la comparte como PNG.
  ///
  /// `pixelRatio: 3` para que no salga pixelada al subirla a una story.
  Future<void> _share() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);
    try {
      final boundary =
          _keyFor(_index).currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final dir = await getTemporaryDirectory();
      final file = await _writeTempPng(dir.path, byteData.buffer.asUint8List());
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Mis estadísticas en Syncora Player',
      );
    } catch (_) {
      if (mounted) {
        AppToast.show(context, message: 'No se pudo compartir la tarjeta');
      }
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  Future<File> _writeTempPng(String dirPath, Uint8List bytes) async {
    final file = File('$dirPath/syncora_wrapped_${DateTime.now().millisecondsSinceEpoch}.png');
    return file.writeAsBytes(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(statsSnapshotProvider(widget.period));

    return Scaffold(
      backgroundColor: Colors.black,
      body: async.when(
        loading: () => const Center(child: SkeletonBox(width: 260, height: 460)),
        error: (_, _) => _closable(const Center(
          child: Text('No se pudo cargar tu Wrapped',
              style: TextStyle(color: AppTheme.secondary)),
        )),
        data: (snapshot) {
          if (snapshot.isEmpty) {
            return _closable(const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Necesitas algo de historial para generar tu Wrapped.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.secondary, fontSize: 15),
                ),
              ),
            ));
          }
          return _buildStories(snapshot);
        },
      ),
    );
  }

  Widget _closable(Widget child) => SafeArea(
        child: Stack(children: [
          child,
          Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: Colors.white),
            ),
          ),
        ]),
      );

  Widget _buildStories(StatsSnapshot s) {
    final artists = ref.watch(enrichedArtistsProvider(s.topArtists.take(5).toList())).value ?? [];
    final tracks = ref.watch(enrichedTracksProvider(s.topTracks.take(5).toList())).value ?? [];

    final cards = <_WrappedCardData>[
      _WrappedCardData(
        eyebrow: 'En ${widget.period.longLabel}',
        headline: formatListeningTime(s.totalMs),
        caption: 'de música',
        colors: const [Color(0xFF6366F1), Color(0xFF9333EA)],
        footnote: '${s.totalPlays} reproducciones',
      ),
      if (artists.isNotEmpty)
        _WrappedCardData(
          eyebrow: 'Tu artista número uno',
          headline: artists.first.artist.name,
          caption: formatListeningTime(artists.first.entry.ms),
          colors: const [Color(0xFF0EA5E9), Color(0xFF2563EB)],
          imageUrl: artists.first.artist.pictureUrl,
          circularImage: true,
          list: artists.skip(1).take(4).map((e) => e.artist.name).toList(),
        ),
      if (tracks.isNotEmpty)
        _WrappedCardData(
          eyebrow: 'La canción que más repetiste',
          headline: tracks.first.track.title,
          caption: tracks.first.entry.plays > 0
              ? '${tracks.first.entry.plays} reproducciones'
              : formatListeningTime(tracks.first.entry.ms),
          colors: const [Color(0xFFDB2777), Color(0xFF7C3AED)],
          imageUrl: tracks.first.track.coverUrl,
          list: tracks.skip(1).take(4).map((e) => e.track.title).toList(),
        ),
      if (s.topGenres.isNotEmpty)
        _WrappedCardData(
          eyebrow: 'Tu sonido',
          headline: s.topGenres.first.genre,
          caption: 'tu género principal',
          colors: const [Color(0xFF059669), Color(0xFF0D9488)],
          list: s.topGenres.skip(1).take(4).map((g) => g.genre).toList(),
        ),
      _WrappedCardData(
        eyebrow: 'Tu variedad',
        headline: '${s.distinctArtists}',
        caption: s.distinctArtists == 1 ? 'artista distinto' : 'artistas distintos',
        colors: const [Color(0xFFEA580C), Color(0xFFDB2777)],
        footnote: '${s.distinctTracks} canciones diferentes',
      ),
    ];

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                for (var i = 0; i < cards.length; i++)
                  Expanded(
                    child: Container(
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: i <= _index
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: Colors.white),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Compartir',
                onPressed: _isSharing ? null : _share,
                icon: _isSharing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.ios_share, color: Colors.white),
              ),
            ],
          ),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: cards.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 9 / 16,
                    child: RepaintBoundary(
                      key: _keyFor(i),
                      child: _WrappedCard(data: cards[i]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WrappedCardData {
  final String eyebrow;
  final String headline;
  final String caption;
  final List<Color> colors;
  final String? imageUrl;
  final bool circularImage;
  final List<String> list;
  final String? footnote;

  const _WrappedCardData({
    required this.eyebrow,
    required this.headline,
    required this.caption,
    required this.colors,
    this.imageUrl,
    this.circularImage = false,
    this.list = const [],
    this.footnote,
  });
}

class _WrappedCard extends StatelessWidget {
  final _WrappedCardData data;

  const _WrappedCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: data.colors,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              data.eyebrow.toUpperCase(),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
              ),
            ),
            const Spacer(),
            if (data.imageUrl != null && data.imageUrl!.isNotEmpty) ...[
              Center(
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(data.circularImage ? 100 : 16),
                  child: CachedNetworkImage(
                    imageUrl: data.imageUrl!,
                    width: 140,
                    height: 140,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(
                      width: 140,
                      height: 140,
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                    errorWidget: (_, _, _) => Container(
                      width: 140,
                      height: 140,
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                data.headline,
                maxLines: 2,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              data.caption,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 16,
              ),
            ),
            if (data.list.isNotEmpty) ...[
              const SizedBox(height: 20),
              for (var i = 0; i < data.list.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        child: Text(
                          '${i + 2}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          data.list[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const Spacer(),
            Row(
              children: [
                if (data.footnote != null)
                  Expanded(
                    child: Text(
                      data.footnote!,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 13,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                Text(
                  'Syncora Player',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
