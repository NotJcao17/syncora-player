import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/apis/lrclib_api.dart';
import '../player_providers.dart';

/// Letras sincronizadas, compartidas por la hoja de móvil y la vista de
/// escritorio (ronda 5).
///
/// Dos cambios respecto a la versión anterior:
///
/// 1. **El tamaño no reflowea.** Antes la línea activa cambiaba de tamaño de
///    letra (y de grosor). Con un texto largo eso cambiaba los saltos de línea
///    a mitad de la animación y, como las líneas cortas se centraban solas y
///    las largas no, una frase "saltaba" de centrada a alineada a la
///    izquierda. Ahora todas se maquetan con la misma letra y el mismo ancho
///    (el disponible dividido entre [activeScale]) y la activa solo se escala
///    al pintarse: los saltos de línea nunca cambian y la escalada cabe justa.
/// 2. **Se puede leer sin que la pantalla se mueva.** Al desplazarse a mano
///    se deja de seguir la canción y aparece "Sincronizar". Se vuelve a
///    seguir al tocarlo, al tocar una línea o al volver por cuenta propia
///    cerca de la línea que suena.
class SyncedLyricsList extends ConsumerStatefulWidget {
  const SyncedLyricsList({
    super.key,
    required this.lines,
    required this.fontSize,
    this.activeScale = 1.2,
    this.listPadding = const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
    this.lineSpacing = 10,
    this.maxWidth,
    this.showScrollbar = false,
    this.glow = false,
  });

  final List<LrcLine> lines;
  final double fontSize;
  final double activeScale;
  final EdgeInsets listPadding;

  /// Espacio vertical alrededor de cada línea (absorbe lo que crece la activa).
  final double lineSpacing;

  /// Ancho máximo del texto (escritorio), centrado.
  final double? maxWidth;
  final bool showScrollbar;
  final bool glow;

  @override
  ConsumerState<SyncedLyricsList> createState() => _SyncedLyricsListState();
}

class _SyncedLyricsListState extends ConsumerState<SyncedLyricsList> {
  final ScrollController _controller = ScrollController();
  final Map<int, GlobalKey> _keys = {};
  int _lastActive = -1;
  bool _follow = true;

  @override
  void didUpdateWidget(covariant SyncedLyricsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      _keys.clear();
      _lastActive = -1;
      _follow = true;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _activeIndexAt(Duration position) {
    var active = -1;
    for (var i = 0; i < widget.lines.length; i++) {
      if (position >= widget.lines[i].timestamp) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  void _scrollTo(int index, {Duration duration = const Duration(milliseconds: 320)}) {
    if (index < 0 || !_controller.hasClients) return;
    final ctx = _keys[index]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0.5, duration: duration, curve: Curves.easeOutCubic);
      return;
    }
    // La línea no está construida (lejos del viewport): estimación por alto
    // medio y, ya construida, el `ensureVisible` del siguiente cambio afina.
    final position = _controller.position;
    final estimate = index * (widget.fontSize * 1.4 + widget.lineSpacing * 2) - position.viewportDimension / 2;
    _controller.animateTo(
      estimate.clamp(0.0, position.maxScrollExtent),
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  /// ¿La línea que suena quedó cerca del centro tras desplazarse a mano?
  bool _activeLineNearCenter() {
    final ctx = _keys[_lastActive]?.currentContext;
    if (ctx == null || !_controller.hasClients) return false;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.attached) return false;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return false;
    final centered = viewport.getOffsetToReveal(box, 0.5).offset;
    return (centered - _controller.offset).abs() < _controller.position.viewportDimension * 0.2;
  }

  bool _onScroll(ScrollNotification n) {
    if (n is UserScrollNotification && n.direction != ScrollDirection.idle) {
      if (_follow) setState(() => _follow = false);
    } else if (n is ScrollEndNotification && !_follow && _activeLineNearCenter()) {
      setState(() => _follow = true);
    }
    return false;
  }

  void _resync() {
    setState(() => _follow = true);
    _scrollTo(_lastActive, duration: const Duration(milliseconds: 450));
  }

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(playerStateProvider.select((s) => s.engine.position));
    final active = _activeIndexAt(position);
    if (active != _lastActive) {
      _lastActive = active;
      if (_follow && active >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _follow) _scrollTo(active);
        });
      }
    }

    Widget list = ListView.builder(
      controller: _controller,
      padding: widget.listPadding,
      itemCount: widget.lines.length,
      itemBuilder: (context, index) {
        final line = widget.lines[index];
        final tile = _LyricLine(
          key: _keys.putIfAbsent(index, () => GlobalKey()),
          text: line.text.isEmpty ? '♪' : line.text,
          isActive: index == active,
          isPast: index < active,
          fontSize: widget.fontSize,
          activeScale: widget.activeScale,
          spacing: widget.lineSpacing,
          glow: widget.glow,
          onTap: () {
            ref.read(syncoraPlayerControllerProvider.notifier).seek(line.timestamp);
            if (!_follow) setState(() => _follow = true);
          },
        );
        final maxWidth = widget.maxWidth;
        if (maxWidth == null) return tile;
        return Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: tile));
      },
    );
    if (widget.showScrollbar) {
      list = Scrollbar(controller: _controller, thumbVisibility: true, child: list);
    }

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(onNotification: _onScroll, child: list),
        Positioned(
          left: 0,
          right: 0,
          bottom: 20,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _follow ? const SizedBox.shrink() : _SyncButton(onTap: _resync),
            ),
          ),
        ),
      ],
    );
  }
}

class _LyricLine extends StatefulWidget {
  const _LyricLine({
    super.key,
    required this.text,
    required this.isActive,
    required this.isPast,
    required this.fontSize,
    required this.activeScale,
    required this.spacing,
    required this.glow,
    required this.onTap,
  });

  final String text;
  final bool isActive;
  final bool isPast;
  final double fontSize;
  final double activeScale;
  final double spacing;
  final bool glow;
  final VoidCallback onTap;

  @override
  State<_LyricLine> createState() => _LyricLineState();
}

class _LyricLineState extends State<_LyricLine> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (widget.isActive) {
      color = AppTheme.primary;
    } else if (_hovered) {
      color = AppTheme.primary.withValues(alpha: 0.9);
    } else if (widget.isPast) {
      color = AppTheme.secondary.withValues(alpha: 0.5);
    } else {
      color = AppTheme.secondary.withValues(alpha: 0.85);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: widget.spacing),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Maquetado al ancho que cabe escalado: los saltos de línea son
              // los mismos esté activa o no.
              final layoutWidth = constraints.maxWidth / widget.activeScale;
              return Center(
                child: AnimatedScale(
                  scale: widget.isActive ? widget.activeScale : 1.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: SizedBox(
                    width: layoutWidth,
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 220),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: widget.fontSize,
                        // Mismo grosor siempre: cambiarlo también reflowea.
                        fontWeight: FontWeight.w800,
                        height: 1.35,
                        color: color,
                        shadows: widget.glow && widget.isActive ? AppTheme.textGlow : null,
                      ),
                      child: Text(widget.text, textAlign: TextAlign.center),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.primary,
      shape: const StadiumBorder(),
      elevation: 6,
      shadowColor: Colors.black54,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.broken(SolarIcons.Refresh), size: 16, color: AppTheme.background),
              const SizedBox(width: 8),
              const Text(
                'Sincronizar',
                style: TextStyle(color: AppTheme.background, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
