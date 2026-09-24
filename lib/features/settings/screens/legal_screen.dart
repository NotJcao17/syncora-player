import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';

/// Privacidad y aviso legal. Texto estático: describe lo que la app hace hoy
/// de verdad (qué se guarda dónde y a qué servicios se habla). Si cambia algo
/// de eso — una tabla nueva en Supabase, un servicio externo nuevo — este
/// texto tiene que cambiar con ello.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  static const _lastUpdated = '24 de septiembre de 2026';

  static const _sections = <(String, List<String>)>[
    (
      'Qué es Syncora',
      [
        'Syncora es un proyecto personal, gratuito y sin fines de lucro. No tiene publicidad, no vende datos y no '
            'incluye herramientas de analítica ni de rastreo.',
        'Syncora no aloja música. Los datos de canciones, álbumes y artistas vienen del catálogo público de Deezer, '
            'y el audio se obtiene de YouTube en el momento de reproducir o descargar. Syncora no está afiliado a '
            'Deezer, YouTube ni Google.',
      ],
    ),
    (
      'Qué se guarda en tu dispositivo',
      [
        'Tu biblioteca (playlists, álbumes guardados y "Me gusta"), tu historial de escucha, las canciones que '
            'descargas con sus portadas, la caché de imágenes y tus ajustes.',
        'Si guardas tu propia llave de Gemini, se guarda cifrada en el almacenamiento seguro del sistema y solo '
            'sale del dispositivo para acompañar cada petición de IA que hagas.',
        'Puedes borrar las descargas y la caché de imágenes desde Configuración.',
      ],
    ),
    (
      'Qué se guarda en la nube (solo con cuenta)',
      [
        'Con cuenta, tu biblioteca y tu historial de escucha se sincronizan con Supabase, que es donde vive la base '
            'de datos del proyecto. También se guardan tu correo (para iniciar sesión) y la semilla de tu avatar.',
        'El historial detallado de escuchas se borra a los 90 días. Para las estadísticas de largo plazo se conserva '
            'un resumen mensual: minutos totales y tus canciones, artistas y géneros más escuchados.',
        'Cada usuario solo puede leer y modificar sus propios datos. Una playlist solo la ven otras personas si tú '
            'la compartes.',
        'En modo local (sin cuenta) nada de esto sale de tu dispositivo.',
      ],
    ),
    (
      'Servicios externos',
      [
        'Deezer: búsquedas y datos del catálogo. Las consultas salen directamente de tu dispositivo.',
        'YouTube: el audio de cada canción, también directamente desde tu dispositivo.',
        'LRCLib: las letras. Se envía el título, el artista y la duración de la canción.',
        'DiceBear: genera tu avatar. Solo recibe una semilla, que no incluye tu nombre ni tu correo.',
        'Google: inicio de sesión, si eliges entrar con Google.',
        'Gemini (Google): solo si usas una función de IA. Se envía lo que escribes y, según la función, las '
            'canciones de la playlist o de la cola sobre las que trabaja. La petición pasa por el servidor de '
            'Syncora, que no guarda su contenido: solo cuenta cuántas peticiones haces, para el límite de uso.',
        'Cada servicio tiene sus propias condiciones y políticas de privacidad.',
      ],
    ),
    (
      'Tus datos',
      [
        'Puedes exportar cualquier playlist a CSV desde su menú.',
        'Puedes eliminar tu cuenta cuando quieras desde Configuración. Al hacerlo se borran de forma permanente tu '
            'cuenta y todos los datos asociados que están en la nube.',
      ],
    ),
    (
      'Aviso legal',
      [
        'Syncora se ofrece tal cual, sin garantías de ningún tipo. Algunas funciones dependen de servicios de '
            'terceros que pueden cambiar o dejar de funcionar en cualquier momento.',
        'Eres responsable de usar la app de acuerdo con las leyes de tu país y las condiciones de los servicios '
            'de los que obtiene el contenido.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;

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
          'Privacidad y aviso legal',
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
              const Text(
                'Última actualización: $_lastUpdated',
                style: TextStyle(color: AppTheme.secondary, fontSize: 12),
              ),
              for (final (title, paragraphs) in _sections) ...[
                const SizedBox(height: 24),
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                for (final paragraph in paragraphs) ...[
                  const SizedBox(height: 10),
                  Text(
                    paragraph,
                    style: const TextStyle(color: AppTheme.secondary, fontSize: 14, height: 1.5),
                  ),
                ],
              ],
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
