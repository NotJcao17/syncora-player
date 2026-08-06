import 'package:flutter/material.dart';

/// Componente de texto en marquesina (Marquee) con autodesplazamiento horizontal.
///
/// Si el texto sobrepasa el ancho disponible del contenedor, inicia una animación
/// suave de desplazamiento horizontal continuo. Si cabe sin desbordar, se muestra
/// de forma estática centrada/alineada normalmente.
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Axis scrollAxis;
  final double velocity;
  final double blankSpace;
  final Duration pauseDuration;

  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.scrollAxis = Axis.horizontal,
    this.velocity = 30.0,
    this.blankSpace = 30.0,
    this.pauseDuration = const Duration(seconds: 2),
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  bool _shouldScroll = false;
  bool _isAnimating = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflowAndStart());
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _isAnimating = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflowAndStart());
    }
  }

  void _checkOverflowAndStart() async {
    if (!mounted) return;
    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();

    final textWidth = textPainter.width;
    final containerWidth = context.size?.width ?? 0;

    final overflow = textWidth > containerWidth && containerWidth > 0;

    if (overflow != _shouldScroll) {
      setState(() {
        _shouldScroll = overflow;
      });
    }

    if (overflow && !_isAnimating) {
      _startMarqueeAnimation();
    }
  }

  void _startMarqueeAnimation() async {
    if (_isAnimating || !mounted) return;
    _isAnimating = true;

    while (mounted && _shouldScroll && _isAnimating) {
      await Future.delayed(widget.pauseDuration);
      if (!mounted || !_isAnimating || !_scrollController.hasClients) break;

      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll <= 0) break;

      final durationSeconds = maxScroll / widget.velocity;
      final duration = Duration(milliseconds: (durationSeconds * 1000).toInt());

      await _scrollController.animateTo(
        maxScroll,
        duration: duration,
        curve: Curves.linear,
      );

      if (!mounted || !_isAnimating || !_scrollController.hasClients) break;
      await Future.delayed(widget.pauseDuration);

      if (!mounted || !_isAnimating || !_scrollController.hasClients) break;
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _isAnimating = false;
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textPainter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();

        final isOverflowing = textPainter.width > constraints.maxWidth && constraints.maxWidth > 0;

        if (!isOverflowing) {
          return Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

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
