/// Lógica pura de medición de escucha, sin motor de audio ni Drift detrás
/// (mismo patrón que `computeCanEdit` / `computeAuthRedirect`): así el caso
/// difícil — distinguir un seek de un tick de posición que llegó tarde —
/// puede fijarse con un test de mesa en vez de con un reproductor real.
library;

/// Tope de avance que se considera natural aunque el reloj no lo respalde.
///
/// Cubre el caso normal de ticks rápidos, donde apenas pasó tiempo real entre
/// dos lecturas y medir contra el reloj sería demasiado ruidoso.
const Duration kMaxNaturalPositionJump = Duration(seconds: 3);

/// Holgura que se suma al tiempo de reloj transcurrido antes de declarar que
/// un avance de posición fue un seek.
const Duration kPositionJumpClockTolerance = Duration(seconds: 2);

/// Cuánto del avance de posición entre dos lecturas del motor cuenta como
/// escucha real.
///
/// Devuelve [Duration.zero] cuando no debe contarse nada: en pausa, si la
/// posición no avanzó (o retrocedió, que es un seek hacia atrás), o si avanzó
/// **más rápido de lo que puede avanzar el reloj**, que es la firma de un
/// seek hacia adelante.
///
/// El criterio del reloj es lo que arregla H-S1. El filtro anterior era solo
/// `delta <= kMaxNaturalPositionJump`, y descartaba entero cualquier tick que
/// llegara tarde — algo habitual con la pantalla apagada en Android, y con
/// cadencias distintas entre `media_kit` (Windows) y `just_audio` (Android).
/// El resultado eran minutos perdidos, y perdidos de forma distinta en cada
/// plataforma.
///
/// [sinceLastTick] nulo significa que esta es la primera lectura de la
/// escucha y no hay reloj contra el que contrastar: se cae al tope fijo.
Duration naturalListenDelta({
  required Duration previousPosition,
  required Duration newPosition,
  required bool playing,
  Duration? sinceLastTick,
}) {
  if (!playing) return Duration.zero;

  final delta = newPosition - previousPosition;
  if (delta <= Duration.zero) return Duration.zero;

  final clockAllowance =
      sinceLastTick == null ? kMaxNaturalPositionJump : sinceLastTick + kPositionJumpClockTolerance;
  final allowance =
      clockAllowance > kMaxNaturalPositionJump ? clockAllowance : kMaxNaturalPositionJump;

  return delta <= allowance ? delta : Duration.zero;
}
