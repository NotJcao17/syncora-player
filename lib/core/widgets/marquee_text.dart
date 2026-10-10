import 'package:flutter/widgets.dart';

/// Componente de texto en marquesina (Marquee) con autodesplazamiento horizontal.
///
/// Si el texto sobrepasa el ancho disponible del contenedor, se desplaza en
/// horizontal; si cabe, se muestra estático. Cuando no se desplaza, el texto
/// largo se corta con "…".
///
/// **Se mueve poco a propósito (consumo de CPU).** Mientras una animación está
/// activa, Flutter redibuja la ventana a 60 cuadros por segundo; antes este
/// texto se movía sin parar, también en pausa, y era buena parte del 5-6 % de
/// CPU que se veía en Windows con la app en reposo. Ahora solo se mueve con
/// [animate] en `true` (los reproductores pasan "está sonando"), da
/// [maxLoops] vueltas y se detiene, y no se mueve con la app oculta o
/// minimizada. Vuelve a empezar al cambiar el texto o al pasar [animate] de
/// `false` a `true`.
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Axis scrollAxis;
  final double velocity;
  final double blankSpace;
  final Duration pauseDuration;

  /// Si puede desplazarse ahora (p. ej. solo mientras suena la canción).
  final bool animate;

  /// Vueltas completas antes de quedarse quieto.
  final int maxLoops;

  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.scrollAxis = Axis.horizontal,
    this.velocity = 30.0,
    this.blankSpace = 30.0,
    this.pauseDuration = const Duration(seconds: 2),
    this.animate = true,
    this.maxLoops = 3,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  // Sin `keepScrollOffset`: al volver a mostrarse debe empezar desde el
  // principio, no donde se quedó la vez anterior.
  final ScrollController _scrollController = ScrollController(keepScrollOffset: false);
  late final AppLifecycleListener _lifecycle;

  /// Cambia cada vez que el ciclo en curso debe abandonarse.
  int _loopToken = 0;
  bool _looping = false;
  bool _finished = false;
  bool _appVisible = true;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => _setVisible(false),
      onShow: () => _setVisible(true),
    );
  }

  void _setVisible(bool visible) {
    if (_appVisible == visible || !mounted) return;
    setState(() {
      _appVisible = visible;
      if (!visible) _stop();
    });
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    final textChanged = oldWidget.text != widget.text || oldWidget.style != widget.style;
    final resumed = !oldWidget.animate && widget.animate;
    if (textChanged || resumed) {
      _stop();
      _finished = false;
    } else if (oldWidget.animate && !widget.animate) {
      _stop();
    }
  }

  bool get _isTestEnv {
    try {
      final name = WidgetsBinding.instance.runtimeType.toString();
      return name.contains('Test') || name.contains('Automated');
    } catch (_) {
      return true;
    }
  }

  /// Abandona el ciclo en curso. Se puede llamar durante el build: el regreso
  /// al principio se hace después del cuadro.
  void _stop() {
    _loopToken++;
    _looping = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_looping && _scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  void _ensureLooping() {
    if (_looping || _isTestEnv) return;
    _looping = true;
    final token = ++_loopToken;
    WidgetsBinding.instance.addPostFrameCallback((_) => _runLoop(token));
  }

  bool _alive(int token) => mounted && token == _loopToken && _scrollController.hasClients;

  Future<void> _runLoop(int token) async {
    for (var loop = 0; loop < widget.maxLoops; loop++) {
      await Future.delayed(widget.pauseDuration);
      if (!_alive(token)) return;

      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll <= 0) break;

      await _scrollController.animateTo(
        maxScroll,
        duration: Duration(milliseconds: (maxScroll / widget.velocity * 1000).toInt()),
        curve: Curves.linear,
      );
      if (!_alive(token)) return;

      await Future.delayed(widget.pauseDuration);
      if (!_alive(token)) return;

      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOut,
      );
      if (!_alive(token)) return;
    }
    if (mounted && token == _loopToken) {
      setState(() {
        _looping = false;
        _finished = true;
      });
    }
  }

  @override
  void dispose() {
    _loopToken++;
    _lifecycle.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _static() => Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textPainter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();

        final isOverflowing = constraints.maxWidth.isFinite &&
            constraints.maxWidth > 0 &&
            textPainter.width > constraints.maxWidth;

        final shouldScroll = isOverflowing && widget.animate && _appVisible && !_finished && !_isTestEnv;
        if (!shouldScroll) {
          if (_looping) _stop();
          return _static();
        }

        _ensureLooping();
        return SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: widget.scrollAxis,
          physics: const NeverScrollableScrollPhysics(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.text, style: widget.style),
              SizedBox(width: widget.blankSpace),
              Text(widget.text, style: widget.style),
            ],
          ),
        );
      },
    );
  }
}
