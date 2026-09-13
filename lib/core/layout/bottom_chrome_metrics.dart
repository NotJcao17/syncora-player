import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

/// Alto real del "chrome" inferior de móvil (mini reproductor + barra de
/// navegación), **medido en cada frame** en vez de estimado con constantes.
///
/// Ronda 3 (E3) puso las constantes en un solo sitio, pero seguían siendo
/// estimaciones: bastó con que el mini reproductor ganara su barra de progreso
/// para que el aviso de "me gusta" volviera a quedar montado encima de él.
/// Medir el widget real cierra esa clase de bug de una vez: cualquier cambio
/// futuro de altura se refleja solo.
///
/// `0` significa "no hay chrome que esquivar" — desktop, o una ruta a pantalla
/// completa por encima del shell.
final bottomChromeHeightProvider = StateProvider<double>((ref) => 0);

/// Marca un subárbol como "aquí NO se ve el chrome inferior del shell".
///
/// Lo usan las rutas que se empujan por encima del shell (el reproductor a
/// pantalla completa, la pantalla de Cola): allí un aviso debe ir pegado al
/// borde inferior, porque no hay mini reproductor ni barra de navegación que
/// esquivar. Sin esto, un aviso lanzado desde la pantalla de Cola aparecía
/// flotando a media pantalla.
///
/// Es un `InheritedWidget` y no un provider a propósito: depende de **dónde**
/// se dispara el aviso, no de un estado global.
class BottomChromeScope extends InheritedWidget {
  const BottomChromeScope({
    super.key,
    required this.hasChrome,
    required super.child,
  });

  final bool hasChrome;

  /// `true` (el default, cuando no hay ningún scope arriba) = estamos dentro
  /// del shell y hay chrome que esquivar.
  static bool hasChromeAt(BuildContext context) {
    final element = context.getElementForInheritedWidgetOfExactType<BottomChromeScope>();
    final widget = element?.widget;
    return widget is BottomChromeScope ? widget.hasChrome : true;
  }

  @override
  bool updateShouldNotify(BottomChromeScope oldWidget) => hasChrome != oldWidget.hasChrome;
}

/// Reporta el alto real de [child] a [bottomChromeHeightProvider].
///
/// Mide después del layout (`addPostFrameCallback`) y solo escribe cuando el
/// valor cambia de verdad, así que no provoca un bucle de rebuilds.
class MeasuredBottomChrome extends ConsumerStatefulWidget {
  const MeasuredBottomChrome({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MeasuredBottomChrome> createState() => _MeasuredBottomChromeState();
}

class _MeasuredBottomChromeState extends ConsumerState<MeasuredBottomChrome> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(MeasuredBottomChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasure();
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _key.currentContext?.findRenderObject() as RenderBox?;
      final height = box?.size.height ?? 0;
      final current = ref.read(bottomChromeHeightProvider);
      // Tolerancia de medio píxel: evita reescribir por ruido de redondeo.
      if ((current - height).abs() < 0.5) return;
      ref.read(bottomChromeHeightProvider.notifier).state = height;
    });
  }

  @override
  Widget build(BuildContext context) {
    // El mini reproductor aparece y desaparece con la pista activa, así que
    // hay que remedir en cada build, no solo al montar.
    _scheduleMeasure();
    return KeyedSubtree(key: _key, child: widget.child);
  }
}
