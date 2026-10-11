import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/auth/services/desktop_auth_pages.dart';

void main() {
  test('la página de error escapa lo que llega en la URL del callback', () {
    final html = desktopAuthErrorPage('<script>x</script>', '"><img src=x onerror=alert(1)>');
    expect(html, isNot(contains('<script>x')));
    expect(html, isNot(contains('<img src=x')));
    expect(html, contains('&lt;script&gt;'));
  });

  test('las páginas usan los colores de la app, sin el morado genérico', () {
    for (final html in [desktopAuthSuccessPage(), desktopAuthErrorPage('e', null)]) {
      expect(html, contains('#181C27'));
      expect(html.toLowerCase(), isNot(contains('#7b5cfa')));
    }
  });
}
