/// Fase 7.H.4 -- detecta si un mensaje de error de Supabase Auth corresponde
/// al rechazo del hook "Before User Created" (7.H.2) por cupo de 250
/// cuentas lleno (D-22).
///
/// Reconoce **dos** formas del mismo error, no solo el mensaje personalizado
/// que devuelve la función de Postgres
/// (`before_user_created_account_limit`, migración
/// `20250001000009_account_limit.sql`): hay un bug conocido de la
/// plataforma Supabase donde, al rechazar un hook con un mensaje
/// personalizado, la respuesta que llega al cliente puede ser el genérico
/// "Invalid payload sent to hook" en vez del texto propio -- si solo se
/// reconociera el mensaje personalizado, ese camino mostraría un error
/// genérico y confuso justo en el caso que más necesita ser claro (7.H.4).
///
/// El match de `"invalid payload sent to hook"` asume que este es, por
/// ahora, el único Auth Hook configurado en el proyecto -- si en el futuro
/// se agrega otro (ej. junto con 7.I), un fallo genérico de transporte de
/// ESE hook también se reportaría acá como "cupo lleno". Aceptado a
/// propósito por ahora (revisión independiente de 7.H); revisar si se suma
/// un segundo hook.
bool looksLikeAccountLimitError(String message) {
  final lower = message.toLowerCase();
  return lower.contains('cuentas con nube') || lower.contains('invalid payload sent to hook');
}

/// Mensaje amigable mostrado en `auth_screen.dart` cuando se detecta el
/// cupo lleno -- explica que no es un error del usuario y que hay una
/// alternativa, en vez de un error genérico o un "inténtalo más tarde".
const String accountLimitMessage =
    'Las cuentas con nube de Syncora Player están llenas por ahora. Puedes seguir usando la '
    'app sin cuenta mientras se libera cupo.';
