import 'dart:async';

/// Fase 7.H.5 -- puente para que `main.dart` (donde llegan los deep links de
/// OAuth vía `app_links`, sin `BuildContext` ni acceso a `AuthScreen`)
/// pueda avisarle a la UI cuando el callback de OAuth trae un error en vez
/// de una sesión.
///
/// Hallazgo real de la revisión independiente de 7.H: en Android/iOS,
/// `signInWithOAuth` solo abre el navegador y retorna de inmediato -- el
/// resultado real (sesión o error, incluido el rechazo del hook "Before
/// User Created" por cupo lleno, 7.H.2) llega después, por el deep link que
/// procesa `_handleAuthDeepLink` en `main.dart`. Antes de este bridge, ese
/// archivo intentaba extraer una sesión de la URL y, si no había ninguna,
/// simplemente no hacía nada -- CUALQUIER error de OAuth en esas
/// plataformas (no solo el de cupo) desaparecía en silencio, sin que
/// `AuthScreen` se enterara.
final StreamController<String> authDeepLinkErrors = StreamController<String>.broadcast();
