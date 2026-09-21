import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../stats_models.dart';
import '../stats_providers.dart';

/// Wrapped: tarjetas tipo *stories*, una por dato, exportables como imagen.
///
/// **El periodo es el que el usuario elija**, no el año fijo de la versión
/// anterior: se hereda el del dashboard y se puede cambiar desde aquí mismo
/// con el selector de la cabecera.
///
/// En escritorio hay flechas y teclado (←/→) porque ahí no existe el gesto de
/// deslizar: sin eso solo se veía la primera tarjeta.
class WrappedScreen extends ConsumerStatefulWidget {
  final StatsPeriod period;

  const WrappedScreen({super.key, required this.period});

  @override
  ConsumerState<WrappedScreen> createState() => _WrappedScreenState();
}

/// Periodo del Wrapped, separado del del dashboard para que cambiarlo aquí
/// no reordene la pantalla que quedó detrás.
final wrappedPeriodProvider = StateProvider<StatsPeriod?>((ref) => null);

class _WrappedScreenState extends ConsumerState<WrappedScreen> {
  final PageController _pageController = PageController();
  final FocusNode _focusNode = FocusNode();
  final Map<int, GlobalKey> _cardKeys = {};
  int _index = 0;
  int _cardCount = 1;
  bool _isBusy = false;

  GlobalKey _keyFor(int i) => _cardKeys.putIfAbsent(i, () => GlobalKey());

  bool get _isDesktopPlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    // El periodo de partida es el que el usuario tenía elegido en el
    // dashboard.
    Future.microtask(() {
      if (!mounted) return;
      ref.read(wrappedPeriodProvider.notifier).state ??= widget.period;
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    final target = i.clamp(0, _cardCount - 1);
    if (target == _index) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// Rasteriza la tarjeta visible a PNG.
  ///
  /// `pixelRatio: 3` para que no salga pixelada al subirla a una story.
  Future<File?> _renderCard() async {
    final boundary =
        _keyFor(_index).currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return null;

    final dir = await getTemporaryDirectory();
    return _writeTempPng(dir.path, byteData.buffer.asUint8List());
  }

  /// Móvil: hoja de compartir del sistema. Es donde tiene sentido.
  Future<void> _share() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final file = await _renderCard();
      if (file == null) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Mis estadísticas en Syncora Player',
      );
    } catch (_) {
      if (mounted) AppToast.show(context, message: 'No se pudo compartir la tarjeta');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// Escritorio: guardar el PNG en Imágenes/Descargas.
  ///
  /// La hoja de compartir del sistema en Windows acaba ofreciendo Correo y
  /// poco más, que no es lo que nadie quiere hacer con esto. Guardar el
  /// archivo y ofrecer abrir la carpeta es el equivalente útil.
  Future<void> _download() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final temp = await _renderCard();
      if (temp == null) return;

      final target = await _pickDownloadDir();
      final dest = File(
        '${target.path}${Platform.pathSeparator}'
        'syncora_wrapped_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await temp.copy(dest.path);

      if (!mounted) return;
      AppToast.show(
        context,
        message: 'Imagen guardada en ${target.path}',
        actionLabel: 'Copiar ruta',
        onAction: () => Clipboard.setData(ClipboardData(text: dest.path)),
      );
    } catch (_) {
      if (mounted) AppToast.show(context, message: 'No se pudo guardar la imagen');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<Directory> _pickDownloadDir() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {
      // getDownloadsDirectory no está disponible en todas las plataformas.
    }
    return getApplicationDocumentsDirectory();
  }

  Future<File> _writeTempPng(String dirPath, Uint8List bytes) async {
    final file = File('$dirPath/syncora_wrapped_${DateTime.now().millisecondsSinceEpoch}.png');
    return file.writeAsBytes(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final period = ref.watch(wrappedPeriodProvider) ?? widget.period;
    final async = ref.watch(statsSnapshotProvider(period));

    return Scaffold(
      backgroundColor: const Color(0xFF07080C),
      body: async.when(
        loading: () => _chrome(
          period,
          const Center(child: SkeletonBox(width: 260, height: 460)),
        ),
        error: (_, _) => _chrome(
          period,
          const Center(
            child: Text('No se pudo cargar tu Wrapped',
                style: TextStyle(color: AppTheme.secondary)),
          ),
        ),
        data: (snapshot) {
          if (snapshot.isEmpty) {
            return _chrome(
              period,
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Necesitas algo de historial en este periodo para generar '
                    'tu Wrapped.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.secondary, fontSize: 15),
                  ),
                ),
              ),
            );
          }
          return _chrome(period, _stories(snapshot, period));
        },
      ),
    );
  }

  /// Cabecera común: volver, selector de periodo y acción de exportar.
  Widget _chrome(StatsPeriod period, Widget body) {
    return SafeArea(
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Volver',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: Colors.white),
              ),
              Expanded(
                child: _PeriodDropdown(
                  value: period,
                  onChanged: (p) {
                    ref.read(wrappedPeriodProvider.notifier).state = p;
                    setState(() => _index = 0);
                    if (_pageController.hasClients) _pageController.jumpToPage(0);
                  },
                ),
              ),
              IconButton(
                tooltip: _isDesktopPlatform ? 'Guardar imagen' : 'Compartir',
                onPressed: _isBusy ? null : (_isDesktopPlatform ? _download : _share),
                icon: _isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(
                        _isDesktopPlatform ? Icons.download_rounded : Icons.ios_share,
                        color: Colors.white,
                      ),
              ),
            ],
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _stories(StatsSnapshot s, StatsPeriod period) {
    final artistMeta = ref.watch(artistMetaProvider(statsIdsKey(s.topArtists.take(5)))).value ?? {};
    final trackMeta = ref.watch(trackMetaProvider(statsIdsKey(s.topTracks.take(5)))).value ?? {};
    final artists = zipArtists(s.topArtists.take(5).toList(), artistMeta);
    final tracks = zipTracks(s.topTracks.take(5).toList(), trackMeta);

    final cards = buildWrappedCards(
      snapshot: s,
      period: period,
      artists: artists,
      tracks: tracks,
    );
    _cardCount = cards.length;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _goTo(_index + 1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _goTo(_index - 1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                for (var i = 0; i < cards.length; i++)
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _goTo(i),
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
                  ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                // Las flechas solo en escritorio: en móvil se desliza, y ahí
                // ocuparían espacio de tarjeta sin aportar nada.
                if (_isDesktopPlatform)
                  _NavArrow(
                    icon: Icons.chevron_left_rounded,
                    enabled: _index > 0,
                    onTap: () => _goTo(_index - 1),
                  ),
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: cards.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 9 / 16,
                          child: RepaintBoundary(
                            key: _keyFor(i),
                            child: WrappedCard(data: cards[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_isDesktopPlatform)
                  _NavArrow(
                    icon: Icons.chevron_right_rounded,
                    enabled: _index < cards.length - 1,
                    onTap: () => _goTo(_index + 1),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavArrow extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _NavArrow({required this.icon, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: IconButton(
        onPressed: enabled ? onTap : null,
        iconSize: 34,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: enabled ? 0.10 : 0.03),
          shape: const CircleBorder(),
        ),
        icon: Icon(
          icon,
          color: Colors.white.withValues(alpha: enabled ? 0.9 : 0.25),
        ),
      ),
    );
  }
}

class _PeriodDropdown extends StatelessWidget {
  final StatsPeriod value;
  final ValueChanged<StatsPeriod> onChanged;

  const _PeriodDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DropdownButtonHideUnderline(
        child: DropdownButton<StatsPeriod>(
          value: value,
          isDense: true,
          dropdownColor: AppTheme.surfaceActive,
          borderRadius: BorderRadius.circular(12),
          icon: const Icon(Icons.expand_more_rounded, color: Colors.white70, size: 20),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          items: [
            for (final p in StatsPeriod.values)
              DropdownMenuItem(value: p, child: Text(p.label)),
          ],
          onChanged: (p) => p == null ? null : onChanged(p),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// Contenido de las tarjetas
// ----------------------------------------------------------------------

/// Cómo se pinta el cuerpo de una tarjeta. Tener varias plantillas es lo que
/// evita que el Wrapped sea cinco veces el mismo rectángulo con otro texto.
enum WrappedLayout {
  /// Una cifra enorme (tiempo total, número de artistas).
  bigNumber,

  /// Portada grande arriba y el top debajo, numerado.
  spotlight,

  /// Ranking con barras de proporción.
  ranking,

  /// Rejilla de cifras sueltas.
  facts,
}

class WrappedCardData {
  final String eyebrow;
  final String headline;
  final String caption;
  final List<Color> colors;
  final WrappedLayout layout;
  final String? imageUrl;
  final bool circularImage;

  /// Filas del ranking: etiqueta, valor y proporción (0..1) para la barra.
  final List<({String label, String value, double fraction})> rows;

  /// Cifras sueltas del layout [WrappedLayout.facts].
  final List<({String label, String value})> facts;

  final String? footnote;

  const WrappedCardData({
    required this.eyebrow,
    required this.headline,
    required this.caption,
    required this.colors,
    required this.layout,
    this.imageUrl,
    this.circularImage = false,
    this.rows = const [],
    this.facts = const [],
    this.footnote,
  });
}

/// Construye las tarjetas a partir del snapshot.
///
/// Función libre y pura para poder probar qué tarjetas salen según los datos
/// disponibles (sin géneros, sin artistas, etc.) sin montar la pantalla.
List<WrappedCardData> buildWrappedCards({
  required StatsSnapshot snapshot,
  required StatsPeriod period,
  required List<EnrichedArtist> artists,
  required List<EnrichedTrack> tracks,
}) {
  final s = snapshot;
  final cards = <WrappedCardData>[];

  cards.add(WrappedCardData(
    eyebrow: 'En ${period.longLabel}',
    headline: formatListeningTime(s.totalMs),
    caption: 'escuchando música',
    colors: const [Color(0xFF6366F1), Color(0xFF9333EA)],
    layout: WrappedLayout.bigNumber,
    footnote: '${s.totalPlays} reproducciones en total',
  ));

  if (artists.isNotEmpty) {
    final max = artists.first.entry.ms;
    cards.add(WrappedCardData(
      eyebrow: 'Tu artista número uno',
      headline: artists.first.artist.name,
      caption: formatListeningTime(artists.first.entry.ms),
      colors: const [Color(0xFF0EA5E9), Color(0xFF1D4ED8)],
      layout: WrappedLayout.spotlight,
      imageUrl: artists.first.artist.pictureUrl,
      circularImage: true,
      rows: [
        for (final a in artists.skip(1).take(4))
          (
            label: a.artist.name,
            value: formatListeningTime(a.entry.ms),
            fraction: max == 0 ? 0.0 : a.entry.ms / max,
          ),
      ],
    ));
  }

  if (tracks.isNotEmpty) {
    final max = tracks.first.entry.plays > 0
        ? tracks.first.entry.plays.toDouble()
        : tracks.first.entry.ms.toDouble();
    cards.add(WrappedCardData(
      eyebrow: 'La que más repetiste',
      headline: tracks.first.track.title,
      caption: tracks.first.track.artistName.isNotEmpty
          ? tracks.first.track.artistName
          : formatListeningTime(tracks.first.entry.ms),
      colors: const [Color(0xFFDB2777), Color(0xFF7C3AED)],
      layout: WrappedLayout.spotlight,
      imageUrl: tracks.first.track.coverUrl,
      rows: [
        for (final t in tracks.skip(1).take(4))
          (
            label: t.track.title,
            value: t.entry.plays > 0
                ? '${t.entry.plays}×'
                : formatListeningTime(t.entry.ms),
            fraction: max == 0
                ? 0.0
                : (t.entry.plays > 0 ? t.entry.plays / max : t.entry.ms / max),
          ),
      ],
      footnote: tracks.first.entry.plays > 0
          ? 'La pusiste ${tracks.first.entry.plays} veces'
          : null,
    ));
  }

  if (s.topGenres.isNotEmpty) {
    final total = s.topGenres.fold<int>(0, (a, g) => a + g.ms);
    cards.add(WrappedCardData(
      eyebrow: 'Tu sonido',
      headline: s.topGenres.first.genre,
      caption: total == 0
          ? 'tu género principal'
          : '${(s.topGenres.first.ms / total * 100).round()} % de lo que escuchaste',
      colors: const [Color(0xFF059669), Color(0xFF0D9488)],
      layout: WrappedLayout.ranking,
      rows: [
        for (final g in s.topGenres.take(5))
          (
            label: g.genre,
            value: total == 0 ? '' : '${(g.ms / total * 100).round()} %',
            fraction: total == 0 ? 0.0 : g.ms / total,
          ),
      ],
    ));
  }

  // Momento favorito, del mapa de hábitos: un dato que antes no se usaba
  // para nada y que es de los que más gustan.
  final peak = _peakSlot(s.hours);
  if (peak != null) {
    cards.add(WrappedCardData(
      eyebrow: 'Tu momento favorito',
      headline: peak.label,
      caption: 'es cuando más música pones',
      colors: const [Color(0xFF7C3AED), Color(0xFF2563EB)],
      layout: WrappedLayout.bigNumber,
      footnote: '${formatListeningTime(peak.ms)} solo en esa franja',
    ));
  }

  cards.add(WrappedCardData(
    eyebrow: 'Tu variedad',
    headline: '${s.distinctArtists}',
    caption: s.distinctArtists == 1 ? 'artista distinto' : 'artistas distintos',
    colors: const [Color(0xFFEA580C), Color(0xFFDB2777)],
    layout: WrappedLayout.facts,
    facts: [
      (label: 'Canciones diferentes', value: '${s.distinctTracks}'),
      (label: 'Álbumes', value: '${s.distinctAlbums}'),
      (label: 'Reproducciones', value: '${s.totalPlays}'),
      if (s.activeDays > 0) (label: 'Días con música', value: '${s.activeDays}'),
    ],
  ));

  return cards;
}

/// Franja horaria con más escucha, ya redactada ("Los viernes por la noche").
({String label, int ms})? _peakSlot(List<HourCell> hours) {
  if (hours.isEmpty) return null;

  // Se agrupa en franjas de 3 h: una hora suelta es demasiado fino para que
  // el dato suene a algo.
  final buckets = <int, int>{};
  for (final h in hours) {
    final key = h.dow * 8 + (h.hour ~/ 3).clamp(0, 7);
    buckets[key] = (buckets[key] ?? 0) + h.ms;
  }
  if (buckets.isEmpty) return null;

  final best = buckets.entries.reduce((a, b) => b.value > a.value ? b : a);
  if (best.value == 0) return null;

  const dias = [
    'domingos', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábados',
  ];
  final dow = (best.key ~/ 8).clamp(0, 6);
  final startHour = (best.key % 8) * 3;
  final franja = switch (startHour) {
    0 || 3 => 'de madrugada',
    6 || 9 => 'por la mañana',
    12 || 15 => 'por la tarde',
    _ => 'por la noche',
  };

  return (label: 'Los ${dias[dow]}\n$franja', ms: best.value);
}

class WrappedCard extends StatelessWidget {
  final WrappedCardData data;

  const WrappedCard({super.key, required this.data});

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
        boxShadow: [
          BoxShadow(
            color: data.colors.last.withValues(alpha: 0.35),
            blurRadius: 40,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            // Dos círculos muy tenues: rompen el degradado plano y dan
            // profundidad sin competir con el texto.
            Positioned(
              top: -60,
              right: -50,
              child: _Blob(size: 220, alpha: 0.12),
            ),
            Positioned(
              bottom: -70,
              left: -60,
              child: _Blob(size: 200, alpha: 0.08),
            ),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.eyebrow.toUpperCase(),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                  Expanded(child: _body(context)),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          data.footnote ?? '',
                          maxLines: 2,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Syncora',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) => switch (data.layout) {
        WrappedLayout.bigNumber => _bigNumber(),
        WrappedLayout.spotlight => _spotlight(),
        WrappedLayout.ranking => _ranking(),
        WrappedLayout.facts => _facts(),
      };

  Widget _headline({double size = 40, TextAlign align = TextAlign.left, int maxLines = 3}) =>
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: align == TextAlign.center ? Alignment.center : Alignment.centerLeft,
        child: Text(
          data.headline,
          maxLines: maxLines,
          textAlign: align,
          style: TextStyle(
            color: Colors.white,
            fontSize: size,
            fontWeight: FontWeight.w800,
            height: 1.05,
            letterSpacing: -0.5,
          ),
        ),
      );

  Widget _caption({TextAlign align = TextAlign.left}) => Text(
        data.caption,
        textAlign: align,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.85),
          fontSize: 15,
          height: 1.3,
        ),
      );

  Widget _bigNumber() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _headline(size: 46, align: TextAlign.center),
            const SizedBox(height: 10),
            _caption(align: TextAlign.center),
          ],
        ),
      );

  Widget _spotlight() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          if (data.imageUrl != null && data.imageUrl!.isNotEmpty)
            Center(child: _cover()),
          const SizedBox(height: 18),
          _headline(size: 30, maxLines: 2),
          const SizedBox(height: 4),
          _caption(),
          if (data.rows.isNotEmpty) ...[
            const SizedBox(height: 16),
            Divider(color: Colors.white.withValues(alpha: 0.2), height: 1),
            const SizedBox(height: 10),
            for (var i = 0; i < data.rows.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      child: Text(
                        '${i + 2}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        data.rows[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      data.rows[i].value,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const Spacer(),
        ],
      );

  Widget _cover() {
    final radius = data.circularImage ? 999.0 : 18.0;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CachedNetworkImage(
          imageUrl: data.imageUrl!,
          width: 150,
          height: 150,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(
            width: 150,
            height: 150,
            color: Colors.white.withValues(alpha: 0.15),
          ),
          errorWidget: (_, _, _) => Container(
            width: 150,
            height: 150,
            color: Colors.white.withValues(alpha: 0.15),
            child: const Icon(Icons.music_note, color: Colors.white54, size: 40),
          ),
        ),
      ),
    );
  }

  Widget _ranking() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          _headline(size: 36, maxLines: 2),
          const SizedBox(height: 4),
          _caption(),
          const SizedBox(height: 22),
          for (final row in data.rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        row.value,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: row.fraction.clamp(0.02, 1.0),
                      minHeight: 6,
                      backgroundColor: Colors.white.withValues(alpha: 0.18),
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          const Spacer(),
        ],
      );

  Widget _facts() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          _headline(size: 64),
          const SizedBox(height: 2),
          _caption(),
          const SizedBox(height: 26),
          for (final f in data.facts)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    f.value,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      f.label,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const Spacer(),
        ],
      );
}

class _Blob extends StatelessWidget {
  final double size;
  final double alpha;

  const _Blob({required this.size, required this.alpha});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            Colors.white.withValues(alpha: alpha),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0.2, 1.0],
        ),
      ),
    );
  }
}
