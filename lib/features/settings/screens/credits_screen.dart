import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';

/// Créditos y licencia (ronda 4).
///
/// Syncora se publica bajo GPL v3 (ronda 4: primero fue CC BY 4.0, que no
/// está pensada para software; el autor eligió GPL v3 para que nadie pueda
/// sacar una versión cerrada). Aquí se
/// reconoce además lo que la app usa de terceros cuya licencia pide
/// atribución (Solar Icons y el estilo de avatar de DiceBear, ambos CC BY
/// 4.0), el motor de extracción (youtubei.js, MIT) y los servicios de datos.
/// Las licencias completas de todos los paquetes de Dart/Flutter las genera
/// Flutter en "Licencias de código abierto".
class CreditsScreen extends StatelessWidget {
  const CreditsScreen({super.key});

  static const _author = 'Juan Carlos Orozco';
  static const _licenseUrl = 'https://www.gnu.org/licenses/gpl-3.0.html';

  static const _credits = <(String, String, String?)>[
    (
      'youtubei.js',
      'Motor de extracción de audio, por LuanRT y colaboradores. Licencia MIT.',
      'https://github.com/LuanRT/YouTube.js',
    ),
    (
      'Solar Icons',
      'Íconos de la app, por 480 Design. Licencia CC BY 4.0. Integrados con el paquete flutty_solar_icons (MIT).',
      'https://pub.dev/packages/flutty_solar_icons',
    ),
    (
      'DiceBear · Adventurer Neutral',
      'Avatares, estilo "Adventurer Neutral" de Lisa Wischofsky, servido por DiceBear. Licencia CC BY 4.0.',
      'https://www.dicebear.com/styles/adventurer-neutral/',
    ),
    (
      'Deezer API',
      'Catálogo de canciones, álbumes, artistas y portadas. Syncora no está afiliado a Deezer.',
      'https://developers.deezer.com',
    ),
    (
      'LRCLib',
      'Letras sincronizadas, de una base de datos abierta y comunitaria.',
      'https://lrclib.net',
    ),
    (
      'Google Gemini',
      'Funciones de inteligencia artificial.',
      'https://ai.google.dev',
    ),
    (
      'Supabase',
      'Cuentas y sincronización en la nube.',
      'https://supabase.com',
    ),
    (
      'Plus Jakarta Sans',
      'Tipografía, por Tokotype. SIL Open Font License 1.1, vía Google Fonts.',
      'https://fonts.google.com/specimen/Plus+Jakarta+Sans',
    ),
    (
      'Flutter y su ecosistema',
      'Flutter, Dart y los paquetes de código abierto sobre los que está construida la app (just_audio, '
          'media_kit/libmpv, Drift/SQLite, QuickJS vía flutter_js, Riverpod y muchos más).',
      null,
    ),
  ];

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width >= 768;
    const sectionStyle = TextStyle(
      color: AppTheme.primary,
      fontSize: 17,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    );
    const bodyStyle = TextStyle(color: AppTheme.secondary, fontSize: 14, height: 1.5);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: CircleAvatar(
            backgroundColor: AppTheme.surfaceHover,
            child: IconButton(
              icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: AppTheme.primary, size: 20),
              onPressed: () => context.pop(),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
        title: Text(
          'Créditos y licencia',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppTheme.primary,
              ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20, vertical: 16),
            children: [
              const Text('Licencia', style: sectionStyle),
              const SizedBox(height: 10),
              const Text(
                'Syncora Player © 2026 $_author. Es software libre bajo la Licencia Pública General de GNU, '
                'versión 3 (GPL v3): puedes usarlo, estudiarlo, compartirlo y modificarlo, pero cualquier versión '
                'que distribuyas, modificada o no, debe seguir bajo GPL v3, conservar el crédito a $_author e '
                'incluir su código fuente. No se permiten versiones cerradas. Se ofrece sin ninguna garantía.',
                style: bodyStyle,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _open(_licenseUrl),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  child: const Text('Leer la licencia GPL v3', style: TextStyle(color: AppTheme.primary)),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Créditos', style: sectionStyle),
              for (final (name, description, url) in _credits) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: url == null ? null : () => _open(url),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: const TextStyle(color: AppTheme.primary, fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(description, style: bodyStyle),
                            ],
                          ),
                        ),
                        if (url != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 8, top: 2),
                            child: Icon(AppIcons.broken(SolarIcons.ArrowRightUp), color: AppTheme.secondary, size: 16),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'Syncora Player',
                  applicationLegalese: '© 2026 $_author · GPL v3',
                ),
                icon: Icon(AppIcons.broken(SolarIcons.FileText), size: 18),
                label: const Text('Licencias de código abierto'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  side: const BorderSide(color: AppTheme.surfaceHover),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
