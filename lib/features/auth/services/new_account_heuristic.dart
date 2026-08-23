/// Ventana dentro de la cual `createdAt` y `lastSignInAt` se consideran
/// "la misma operación". GoTrue escribe ambos timestamps con el reloj del
/// servidor durante el mismo request de alta, así que la latencia de red
/// del cliente no los separa -- 10 s es holgado de sobra para el jitter
/// real entre las dos escrituras.
const Duration kNewAccountWindow = Duration(seconds: 10);

/// Función pura (mismo patrón que `computeAuthRedirect`/`computeCanEdit`):
/// ¿la sesión que acaba de llegar corresponde a una cuenta recién creada, o
/// a un login sobre una cuenta que ya existía?
///
/// Supabase no le dice al cliente cuál de las dos fue en el flujo de OAuth
/// (`signInWithOAuth`), así que se infiere de los timestamps del usuario:
/// en un alta, `lastSignInAt` cae dentro de [kNewAccountWindow] respecto de
/// `createdAt`; en un login sobre una cuenta vieja, queda muy por delante.
///
/// Ante cualquier duda (timestamp ausente o no parseable) se asume cuenta
/// nueva: ese camino sube/migra la biblioteca local y nunca borra nada, así
/// que es el lado seguro ante un error de clasificación.
bool looksLikeNewAccount({
  required String createdAt,
  required String? lastSignInAt,
}) {
  if (lastSignInAt == null) return true;
  try {
    final created = DateTime.parse(createdAt);
    final lastSignIn = DateTime.parse(lastSignInAt);
    return lastSignIn.difference(created).abs() < kNewAccountWindow;
  } catch (_) {
    return true;
  }
}
