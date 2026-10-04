import 'package:flutter/widgets.dart';

/// Congela el teclado para lo que queda **debajo** de una hoja o diálogo
/// (ronda 5, H-R5-7).
///
/// Mientras el teclado se anima, `MediaQuery` cambia en cada frame
/// (`viewInsets.bottom` y, con él, `padding.bottom`). Todo lo que depende de
/// esos valores se reconstruye o se vuelve a maquetar en cada frame aunque no
/// se vea: el `Scaffold` del shell redimensionando su cuerpo, el `SafeArea`
/// del reproductor a pantalla completa (con un `LayoutBuilder` adentro), las
/// cabeceras de las playlists... Por eso escribir en "Crear cola con IA" iba a
/// tirones.
///
/// Si la ruta que contiene a [child] no es la de arriba, [child] ve siempre
/// el `MediaQuery` "sin teclado". El `MediaQueryData` resultante es igual
/// frame a frame, así que sus dependientes no se enteran de nada. Si la ruta
/// es la de arriba no cambia nada: el teclado de sus propios campos de texto
/// funciona como siempre.
///
/// Siempre devuelve un `MediaQuery`, aunque no cambie nada: si la estructura
/// del árbol cambiara al abrirse una ruta encima, todo [child] (el shell
/// entero) se desmontaría y volvería a crearse. Eso pasó: el menú de perfil
/// del escritorio perdía su botón al abrirse, aparecía en la esquina y su
/// selección se descartaba por `!mounted`.
class KeyboardInsetFreeze extends StatelessWidget {
  const KeyboardInsetFreeze({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final data = MediaQuery.of(context);
    return MediaQuery(
      data: isCurrent ? data : data.copyWith(viewInsets: EdgeInsets.zero, padding: data.viewPadding),
      child: child,
    );
  }
}
