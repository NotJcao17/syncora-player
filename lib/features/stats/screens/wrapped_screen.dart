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

  /// Ancho objetivo del PNG exportado.
  ///
  /// El factor de escala se calcula a partir de esto en vez de fijar un
  /// `pixelRatio: 3` a ciegas: en escritorio la tarjeta ya se dibuja grande,
  /// y multiplicarla por tres daba imágenes de más de 25 millones de píxeles
  /// (>100 MB en memoria antes de comprimir). 1080 px de ancho es resolución
  /// de sobra para una story y acota el pico de memoria.
  static const double _exportTargetWidth = 1080;

  /// Rasteriza la tarjeta visible a PNG.
  ///
  /// En Windows la app corre sobre **Impeller** (por defecto desde Flutter
  /// 3.29), y ahí `toImage` es delicado: si se llama con un frame en vuelo el
  /// hilo de rasterizado puede quedarse bloqueado, y como el proceso sigue
  /// vivo (la música no se corta) parece un cuelgue sin causa. De ahí la
  /// espera a `endOfFrame` y que las tarjetas ya no lleven sombras con
  /// desenfoque: los blurs son justo lo que peor se lleva con esta ruta.
  Future<File?> _renderCard() async {
    final boundary =
        _keyFor(_index).currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;

    // Que no haya nada pintándose cuando se pida la captura.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return null;

    final logicalWidth = boundary.size.width;
    final ratio = logicalWidth <= 0
        ? 2.0
        : (_exportTargetWidth / logicalWidth).clamp(1.0, 3.0);

    // `toImage` devuelve una `ui.Image` respaldada por memoria NATIVA, que el
    // recolector de Dart no libera: hay que cerrarla a mano.
    ui.Image? image;
    try {
      image = await boundary.toImage(pixelRatio: ratio.toDouble());
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;

      final dir = await getTemporaryDirectory();
      return _writeTempPng(dir.path, byteData.buffer.asUint8List());
    } finally {
      image?.dispose();
    }
  }

  /// Apaga el indicador de ocupado sin dar por hecho que el widget sigue
  /// montado: si el usuario cerró la pantalla a mitad, `setState` lanzaría y
  /// el icono se quedaba girando para siempre al volver a entrar.
  void _clearBusy() {
    if (!mounted) {
      _isBusy = false;
      return;
    }
    setState(() => _isBusy = false);
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
    } catch (e, st) {
      // Tragarse la excepción dejaba al usuario con "no pasa nada" y sin
      // ninguna pista en la consola. El detalle va al log y el mensaje corto
      // a la pantalla.
      debugPrint('[Wrapped] Error al compartir: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) {
        AppToast.show(context, message: 'No se pudo compartir la tarjeta: $e');
      }
    } finally {
      _clearBusy();
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
      // El PNG temporal ya no hace falta y puede pesar varios MB.
      try {
        await temp.delete();
      } catch (_) {}

      if (!mounted) return;
      AppToast.show(
        context,
        message: 'Imagen guardada en ${target.path}',
        actionLabel: 'Copiar ruta',
        onAction: () => Clipboard.setData(ClipboardData(text: dest.path)),
      );
    } catch (e, st) {
      debugPrint('[Wrapped] Error al guardar la imagen: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) {
        AppToast.show(context, message: 'No se pudo guardar la imagen: $e');
      }
    } finally {
      _clearBusy();
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

/// Un elemento de un top, ya resuelto con su imagen.
class WrappedItem {
  final String title;
  final String? subtitle;
  final String imageUrl;

  const WrappedItem({required this.title, this.subtitle, this.imageUrl = ''});
}

/// Cómo se pinta el cuerpo de una tarjeta.
///
/// Son solo tres, y a propósito: la versión anterior tenía cinco de las que
/// la mitad decían muy poco ("tu variedad", "tu momento favorito"). Vale más
/// una portada grande con los cinco artistas y las cinco canciones que cinco
/// pantallas con una cifra cada una.
enum WrappedLayout {
  /// Resumen: foto grande, las dos listas, minutos y género.
  summary,

  /// Los cinco artistas con su foto, sin cifras.
  artistShowcase,

  /// Las cinco canciones con su portada, sin cifras.
  trackShowcase,
}

class WrappedCardData {
  final String eyebrow;
  final List<Color> colors;
  final WrappedLayout layout;

  /// Imagen protagonista (foto del artista nº 1).
  final String heroImageUrl;

  final List<WrappedItem> artists;
  final List<WrappedItem> tracks;

  /// Franja inferior del resumen.
  final String totalTime;
  final String topGenre;
  final List<({String label, String value})> facts;

  const WrappedCardData({
    required this.eyebrow,
    required this.colors,
    required this.layout,
    this.heroImageUrl = '',
    this.artists = const [],
    this.tracks = const [],
    this.totalTime = '',
    this.topGenre = '',
    this.facts = const [],
  });
}

/// Construye las tarjetas a partir del snapshot.
///
/// Función libre y pura: se puede comprobar qué tarjetas salen según los
/// datos disponibles (sin géneros, sin artistas…) sin montar la pantalla.
/// Las de artistas y canciones solo aparecen si hay algo que enseñar — una
/// tarjeta vacía es peor que no tenerla.
List<WrappedCardData> buildWrappedCards({
  required StatsSnapshot snapshot,
  required StatsPeriod period,
  required List<EnrichedArtist> artists,
  required List<EnrichedTrack> tracks,
}) {
  final s = snapshot;

  final artistItems = [
    for (final a in artists.take(5))
      WrappedItem(title: a.artist.name, imageUrl: a.artist.pictureUrl),
  ];
  final trackItems = [
    for (final t in tracks.take(5))
      WrappedItem(
        title: t.track.title,
        subtitle: t.track.artistName.isEmpty ? null : t.track.artistName,
        imageUrl: t.track.coverUrl,
      ),
  ];

  final hero = artistItems.isNotEmpty && artistItems.first.imageUrl.isNotEmpty
      ? artistItems.first.imageUrl
      : (trackItems.isNotEmpty ? trackItems.first.imageUrl : '');

  return [
    WrappedCardData(
      eyebrow: 'Tu resumen · ${period.label}',
      colors: const [Color(0xFF6D28D9), Color(0xFF2563EB)],
      layout: WrappedLayout.summary,
      heroImageUrl: hero,
      artists: artistItems,
      tracks: trackItems,
      totalTime: formatListeningTime(s.totalMs),
      topGenre: s.topGenres.isEmpty ? '' : s.topGenres.first.genre,
      facts: [
        (label: 'Artistas', value: '${s.distinctArtists}'),
        (label: 'Canciones', value: '${s.distinctTracks}'),
        (label: 'Reproducciones', value: '${s.totalPlays}'),
      ],
    ),
    if (artistItems.isNotEmpty)
      WrappedCardData(
        eyebrow: 'Tus artistas · ${period.label}',
        colors: const [Color(0xFF0EA5E9), Color(0xFF1E3A8A)],
        layout: WrappedLayout.artistShowcase,
        artists: artistItems,
      ),
    if (trackItems.isNotEmpty)
      WrappedCardData(
        eyebrow: 'Tus canciones · ${period.label}',
        colors: const [Color(0xFFDB2777), Color(0xFF6D28D9)],
        layout: WrappedLayout.trackShowcase,
        tracks: trackItems,
      ),
  ];
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
        // Sin `boxShadow`: un desenfoque dentro de un `RepaintBoundary` que
        // luego se rasteriza con `toImage` es lo que cuelga el hilo de
        // rasterizado en Windows/Impeller. Sobre fondo casi negro la sombra
        // tampoco se veía.
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            const Positioned(top: -70, right: -60, child: _Blob(size: 240, alpha: 0.14)),
            const Positioned(bottom: -80, left: -70, child: _Blob(size: 220, alpha: 0.10)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          data.eyebrow.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.6,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // La marca va arriba como icono, no como texto al pie:
                      // ocupa menos y deja el bloque de contenido centrado
                      // sin una linea suelta en el borde inferior.
                      ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Image.asset(
                          'assets/icon/icon.png',
                          width: 28,
                          height: 28,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(child: _body()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() => switch (data.layout) {
        WrappedLayout.summary => _summary(),
        WrappedLayout.artistShowcase => _artistShowcase(),
        WrappedLayout.trackShowcase => _trackShowcase(),
      };

  // --------------------------------------------------------------------
  // Resumen
  // --------------------------------------------------------------------

  Widget _summary() {
    return LayoutBuilder(
      builder: (context, c) {
        // Un tercio del alto: por debajo de eso las dos listas de cinco no
        // entran sin recortarse.
        final heroSide = (c.maxHeight * 0.34).clamp(80.0, c.maxWidth * 0.64);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          // El sobrante se reparte entre los tres bloques en vez de
          // acumularse todo entre las listas y las cifras, que es lo que
          // dejaba una franja muerta en medio de la tarjeta.
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (data.heroImageUrl.isNotEmpty)
              Center(child: _FramedImage(url: data.heroImageUrl, side: heroSide, radius: 14)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _miniList('Top artistas', data.artists)),
                const SizedBox(width: 12),
                Expanded(child: _miniList('Top canciones', data.tracks)),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: _bigStat('Minutos escuchados', data.totalTime)),
                if (data.topGenre.isNotEmpty)
                  Expanded(child: _bigStat('Género top', data.topGenre)),
              ],
            ),
            const SizedBox(height: 10),
            Divider(color: Colors.white.withValues(alpha: 0.22), height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final f in data.facts)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          f.value,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          f.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _miniList(String title, List<WrappedItem> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.75),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 14,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    items[i].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _bigStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.75),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
              height: 1.1,
              letterSpacing: -0.5,
            ),
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------
  // Artistas: el nº 1 en grande y los otros cuatro en fila
  // --------------------------------------------------------------------

  Widget _artistShowcase() => _showcase(
        items: data.artists,
        circular: true,
        heroRadius: 0,
      );

  Widget _trackShowcase() => _showcase(
        items: data.tracks,
        circular: false,
        heroRadius: 12,
      );

  /// Plantilla común de las dos tarjetas de top: protagonista grande y los
  /// otros cuatro en una fila, sin ninguna cifra — el orden ya cuenta la
  /// historia y los minutos sueltos no aportan nada aquí.
  Widget _showcase({
    required List<WrappedItem> items,
    required bool circular,
    required double heroRadius,
  }) {
    final first = items.first;
    final rest = items.skip(1).toList();

    return LayoutBuilder(
      builder: (context, c) {
        final heroSide = (c.maxHeight * 0.40).clamp(100.0, c.maxWidth * 0.68);
        final smallSide = ((c.maxWidth / 4) - 12).clamp(40.0, 100.0);

        return Column(
          // Centrado. Antes habia un `Spacer` que empujaba la fila de cuatro
          // hasta el borde inferior y dejaba un hueco enorme en medio.
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _FramedImage(
              url: first.imageUrl,
              side: heroSide,
              circular: circular,
              radius: heroRadius,
            ),
            const SizedBox(height: 12),
            Text(
              first.title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 23,
                fontWeight: FontWeight.w800,
                height: 1.15,
              ),
            ),
            if (first.subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  first.subtitle!,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 13,
                  ),
                ),
              ),
            const SizedBox(height: 34),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < rest.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _FramedImage(
                            url: rest[i].imageUrl,
                            side: smallSide,
                            circular: circular,
                            radius: 8,
                            borderWidth: 1.5,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${i + 2}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            rest[i].title,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Imagen con marco claro y sombra, cuadrada o circular.
class _FramedImage extends StatelessWidget {
  final String url;
  final double side;
  final bool circular;
  final double radius;
  final double borderWidth;

  const _FramedImage({
    required this.url,
    required this.side,
    this.circular = false,
    this.radius = 12,
    this.borderWidth = 3,
  });

  @override
  Widget build(BuildContext context) {
    final r = circular ? side : radius;
    final placeholder = Container(
      width: side,
      height: side,
      color: Colors.white.withValues(alpha: 0.15),
      child: Icon(
        circular ? Icons.person : Icons.music_note,
        color: Colors.white54,
        size: side * 0.35,
      ),
    );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.45),
          width: borderWidth,
        ),
        // Sin sombra difuminada, por el mismo motivo que en la tarjeta.
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: url.isEmpty
            ? placeholder
            : CachedNetworkImage(
                imageUrl: url,
                width: side,
                height: side,
                fit: BoxFit.cover,
                placeholder: (_, _) => placeholder,
                errorWidget: (_, _, _) => placeholder,
              ),
      ),
    );
  }
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
