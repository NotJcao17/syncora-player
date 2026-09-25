import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';

/// Carrusel horizontal que **también se puede recorrer en escritorio**.
///
/// Un `ListView` horizontal a secas solo funciona con gestos táctiles: en PC,
/// Flutter no permite arrastrar con el ratón (`dragDevices` excluye el ratón
/// por defecto) y la rueda del ratón desplaza la página en vertical, no el
/// carrusel. Resultado: en Windows el usuario veía las primeras tarjetas y no
/// tenía **ninguna** forma de llegar al resto.
///
/// Esto lo resuelve con dos cosas a la vez:
///
/// - **Arrastre con el ratón habilitado** (`ScrollConfiguration`), que en
///   escritorio es el gesto natural y no interfiere con el clic en una
///   tarjeta: un clic sin movimiento sigue siendo un clic.
/// - **Flechas en los bordes**, visibles al pasar el cursor por encima y solo
///   del lado al que todavía queda contenido.
///
/// Deliberadamente **no** se secuestra la rueda del ratón: sobre un carrusel,
/// la rueda debe seguir desplazando la página, que es lo que el usuario
/// espera y lo que hacen los reproductores de escritorio. Por eso las flechas.
class HorizontalScroller extends StatefulWidget {
  final double height;
  final EdgeInsetsGeometry padding;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double separatorWidth;

  /// Cuánto avanza cada pulsación de flecha. Por defecto, casi un ancho de
  /// pantalla del carrusel.
  final double? pageStep;

  const HorizontalScroller({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = EdgeInsets.zero,
    this.separatorWidth = 16,
    this.pageStep,
  });

  @override
  State<HorizontalScroller> createState() => _HorizontalScrollerState();
}

class _HorizontalScrollerState extends State<HorizontalScroller> {
  final ScrollController _controller = ScrollController();
  bool _isHovered = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateArrows);
    // Al primer frame todavía no hay dimensiones: sin esto, la flecha derecha
    // no aparecería hasta el primer desplazamiento.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void didUpdateWidget(covariant HorizontalScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_updateArrows);
    _controller.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final canLeft = position.pixels > 2;
    final canRight = position.pixels < position.maxScrollExtent - 2;
    if (canLeft != _canScrollLeft || canRight != _canScrollRight) {
      setState(() {
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
      });
    }
  }

  void _scrollBy(double direction) {
    if (!_controller.hasClients) return;
    final viewport = _controller.position.viewportDimension;
    final step = widget.pageStep ?? (viewport * 0.8);
    final target = (_controller.offset + step * direction)
        .clamp(0.0, _controller.position.maxScrollExtent);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width >= 768;

    final list = ScrollConfiguration(
      behavior: const _DragAnywhereScrollBehavior(),
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        itemCount: widget.itemCount,
        separatorBuilder: (_, _) => SizedBox(width: widget.separatorWidth),
        itemBuilder: widget.itemBuilder,
      ),
    );

    if (!isDesktop) {
      return SizedBox(height: widget.height, child: list);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            Positioned.fill(child: list),
            _buildArrow(alignment: Alignment.centerLeft, visible: _canScrollLeft, direction: -1),
            _buildArrow(alignment: Alignment.centerRight, visible: _canScrollRight, direction: 1),
          ],
        ),
      ),
    );
  }

  Widget _buildArrow({
    required Alignment alignment,
    required bool visible,
    required double direction,
  }) {
    final isLeft = direction < 0;

    return Positioned(
      left: isLeft ? 0 : null,
      right: isLeft ? null : 0,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !(visible && _isHovered),
        child: AnimatedOpacity(
          opacity: visible && _isHovered ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: Align(
            alignment: alignment,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Material(
                color: AppTheme.surface,
                shape: const CircleBorder(),
                elevation: 6,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _scrollBy(direction),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(
                      AppIcons.broken(isLeft ? SolarIcons.AltArrowLeft : SolarIcons.AltArrowRight),
                      color: AppTheme.primary,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Permite arrastrar con el ratón y con el lápiz, además del dedo.
class _DragAnywhereScrollBehavior extends MaterialScrollBehavior {
  const _DragAnywhereScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };
}
