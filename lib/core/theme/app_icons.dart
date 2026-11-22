// ignore_for_file: non_const_argument_for_const_parameter

import 'package:flutter/widgets.dart';
import 'package:flutty_solar_icons/flutty_solar_icons.dart';

export 'package:flutty_solar_icons/flutty_solar_icons.dart';

/// Helper para obtener los íconos de Solar Icons con la variante deseada.
///
/// Uso:
/// `AppIcons.broken(SolarIcons.Home)` -> Versión broken (1.5px stroke) por defecto.
/// `AppIcons.bold(SolarIcons.Home)` -> Versión bold (rellena) para estados activos.
abstract class AppIcons {
  static IconData broken(SolarIconData icon) {
    return IconData(
      icon.codePoint,
      fontFamily: 'SolarBroken',
      fontPackage: 'flutty_solar_icons',
    );
  }

  static IconData bold(SolarIconData icon) {
    return IconData(
      icon.codePoint,
      fontFamily: 'SolarBold',
      fontPackage: 'flutty_solar_icons',
    );
  }

  /// Mismo trazo que [broken] pero continuo. Ronda 13: el "+" del reproductor
  /// en versión broken lleva un corte en el círculo que no se parece al resto
  /// de los íconos de la fila.
  static IconData linear(SolarIconData icon) {
    return IconData(
      icon.codePoint,
      fontFamily: 'SolarLinear',
      fontPackage: 'flutty_solar_icons',
    );
  }

  static IconData outline(SolarIconData icon) {
    return IconData(
      icon.codePoint,
      fontFamily: 'SolarOutline',
      fontPackage: 'flutty_solar_icons',
    );
  }
}
