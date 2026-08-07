import 'dart:io';
import 'package:flutter/foundation.dart';
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
  bool _isAnimating = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _isAnimating = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
  }

  void _startAnimationIfNeeded(bool isOverflowing) {
    if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (isOverflowing) {
      if (!_isAnimating) {
        _isAnimating = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _startMarqueeLoop());
      }
    } else {
      if (_isAnimating) {
        _isAnimating = false;
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      }
    }
  }

  void _startMarqueeLoop() async {
    while (mounted && _isAnimating) {
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

        final isOverflowing = constraints.maxWidth.isFinite &&
            constraints.maxWidth > 0 &&
            textPainter.width > constraints.maxWidth;

        _startAnimationIfNeeded(isOverflowing);

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
