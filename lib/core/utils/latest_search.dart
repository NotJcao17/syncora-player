import 'dart:async';

/// Búsqueda "mientras escribes" que solo entrega la respuesta de lo **último**
/// que se escribió.
///
/// Ronda 12: el buscador de "Agregar canciones" de una playlist lanzaba una
/// búsqueda a Deezer por cada letra, sin espera. Las respuestas llegan en
/// cualquier orden (Deezer tarda distinto en cada una), así que la de "bad b"
/// podía llegar después de la de "bad bunny" y pisar los resultados buenos
/// unos segundos más tarde. Además, una petición por tecla va contra el
/// Pitfall #4 (límite de Deezer).
///
/// [run] espera [debounce] sin teclas nuevas antes de buscar, y descarta toda
/// respuesta que no sea de la última consulta.
class LatestSearch<T> {
  LatestSearch({this.debounce = const Duration(milliseconds: 400)});

  final Duration debounce;
  Timer? _timer;
  int _generation = 0;

  /// Programa la búsqueda de [query]. [onResult] solo se llama si nadie pidió
  /// otra consulta mientras tanto; [onError] igual.
  void run(
    String query,
    Future<T> Function(String query) fetch, {
    required void Function(T result) onResult,
    void Function(Object error)? onError,
  }) {
    final generation = ++_generation;
    _timer?.cancel();
    _timer = Timer(debounce, () async {
      try {
        final result = await fetch(query);
        if (generation == _generation) onResult(result);
      } catch (e) {
        if (generation == _generation) onError?.call(e);
      }
    });
  }

  /// Descarta lo pendiente (campo vaciado, pantalla cerrada).
  void cancel() {
    _generation++;
    _timer?.cancel();
  }

  void dispose() => cancel();
}
