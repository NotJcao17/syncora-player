import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/utils/latest_search.dart';

void main() {
  test('una respuesta vieja que llega tarde no pisa la de la última consulta', () {
    fakeAsync((async) {
      final search = LatestSearch<String>(debounce: const Duration(milliseconds: 400));
      final pending = <String, Completer<String>>{};
      final shown = <String>[];
      Future<String> fetch(String q) => (pending[q] = Completer<String>()).future;

      search.run('bad b', fetch, onResult: shown.add);
      async.elapse(const Duration(milliseconds: 500)); // "bad b" sale a la red
      search.run('bad bunny', fetch, onResult: shown.add);
      async.elapse(const Duration(milliseconds: 500)); // "bad bunny" también

      pending['bad bunny']!.complete('resultados de bad bunny');
      async.flushMicrotasks();
      pending['bad b']!.complete('resultados de bad b'); // la lenta, al final
      async.flushMicrotasks();

      expect(shown, ['resultados de bad bunny']);
    });
  });

  test('escribir rápido busca una sola vez, con el texto final', () {
    fakeAsync((async) {
      final search = LatestSearch<String>(debounce: const Duration(milliseconds: 400));
      final asked = <String>[];
      for (final q in ['b', 'ba', 'bad']) {
        search.run(q, (q) async {
          asked.add(q);
          return q;
        }, onResult: (_) {});
        async.elapse(const Duration(milliseconds: 100));
      }
      async.elapse(const Duration(milliseconds: 500));
      expect(asked, ['bad']);
    });
  });

  test('cancelar descarta lo que estaba en camino', () {
    fakeAsync((async) {
      final search = LatestSearch<String>(debounce: Duration.zero);
      final c = Completer<String>();
      final shown = <String>[];
      search.run('x', (_) => c.future, onResult: shown.add);
      async.elapse(Duration.zero);
      search.cancel();
      c.complete('tarde');
      async.flushMicrotasks();
      expect(shown, isEmpty);
    });
  });
}
