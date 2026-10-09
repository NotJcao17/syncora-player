import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';

/// Privacidad y aviso legal. Texto estático: describe lo que la app hace hoy
/// de verdad (qué se guarda dónde y a qué servicios se habla). Si cambia algo
/// de eso — una tabla nueva en Supabase, un servicio externo nuevo — este
/// texto tiene que cambiar con ello.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  static const _lastUpdated = '9 de octubre de 2026';

  static const _sections = <(String, List<String>)>[
    (
      'Qué es Syncora',
      [
        'Syncora es un proyecto personal, gratuito y sin fines de lucro. No tiene publicidad, no vende datos y no '
            'incluye herramientas de analítica ni de rastreo.',
        'Syncora no aloja, no posee y no distribuye música ni ningún otro contenido protegido por derechos de '
            'autor. Funciona como un cliente: los datos de canciones, álbumes y artistas vienen del catálogo público '
            'de Deezer, las letras de LRCLib y el audio se obtiene de YouTube desde tu dispositivo, en el momento de '
            'reproducir o descargar. Syncora no está afiliado a Deezer, YouTube ni Google.',
      ],
    ),
    (
      'Qué se guarda en tu dispositivo',
      [
        'Tu biblioteca (playlists, álbumes guardados y "Me gusta"), tu historial de escucha, las canciones que '
            'descargas con sus portadas, la caché de imágenes y tus ajustes. En modo local, también las imágenes que '
            'eliges como portada de una playlist o como foto de perfil.',
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
        'Si subes una imagen como portada de una playlist o como foto de perfil, se guarda en Cloudflare R2. Antes '
            'de salir de tu dispositivo se recorta, se reduce y se vuelve a codificar, lo que elimina sus metadatos '
            '(ubicación, cámara, fecha). Queda en una dirección pública difícil de adivinar: cualquiera que tenga el '
            'enlace puede verla, y la portada de una playlist que compartes la ve quien vea la playlist. Al '
            'cambiarla o quitarla, la anterior se borra.',
        'El historial detallado de escuchas se borra a los 90 días. Para las estadísticas de largo plazo se conserva '
            'un resumen mensual: minutos totales y tus canciones, artistas y géneros más escuchados.',
        'Cada usuario solo puede leer y modificar sus propios datos. Una playlist solo la ven otras personas si tú '
            'la compartes.',
        'Compartir una playlist la vuelve pública: cualquiera con el enlace puede ver su nombre, descripción, '
            'portada y canciones en syncoraplayer.app, y otros usuarios de Syncora pueden guardarla en su biblioteca '
            'para escucharla (sin poder modificarla). No se muestra tu nombre ni tu correo. Puedes dejar de '
            'compartirla cuando quieras desde su menú.',
        'En modo local (sin cuenta) nada de esto sale de tu dispositivo.',
      ],
    ),
    (
      'Servicios externos',
      [
        'Deezer: búsquedas y datos del catálogo. Las consultas salen directamente de tu dispositivo.',
        'YouTube y YouTube Music: el audio de cada canción y la búsqueda por fragmento de letra, también '
            'directamente desde tu dispositivo.',
        'LRCLib: las letras. Se envía el título, el artista y la duración de la canción.',
        'DiceBear: genera tu avatar si no subes una foto. Solo recibe una semilla, que no incluye tu nombre ni tu '
            'correo.',
        'Cloudflare R2: guarda las imágenes que subes con cuenta. La subida pasa por el servidor de Syncora, que '
            'comprueba que la playlist sea tuya y limita cuántas imágenes puedes subir.',
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
            'cuenta y todos los datos asociados que están en la nube, incluidas las imágenes que subiste.',
      ],
    ),
    (
      'Aviso legal',
      [
        'Todas las canciones, grabaciones, portadas, letras y marcas pertenecen a sus respectivos titulares y '
            'están protegidas por las leyes de derechos de autor. Syncora no fomenta ni respalda la infracción de '
            'derechos de autor: las descargas son para escuchar sin conexión dentro de la app, para uso personal y '
            'no comercial.',
        'Eres el único responsable de que tu uso de Syncora cumpla con las leyes de tu país, las normas de '
            'derechos de autor y los términos de servicio de las plataformas de las que se obtiene el contenido.',
        'Syncora se ofrece tal cual, sin garantías de ningún tipo. Algunas funciones dependen de servicios de '
            'terceros que pueden cambiar o dejar de funcionar en cualquier momento. Sus desarrolladores no se hacen '
            'responsables del uso indebido de la app.',
        'También eres responsable de las imágenes que subes: no subas imágenes que no tengas derecho a usar ni '
            'contenido ofensivo, sobre todo en playlists que compartes.',
      ],
    ),
  ];

  static const _links = <(String, String)>[
    ('Aviso de privacidad', 'https://syncoraplayer.app/privacidad/'),
    ('Términos y aviso legal', 'https://syncoraplayer.app/terminos/'),
    ('contacto@syncoraplayer.app', 'mailto:contacto@syncoraplayer.app'),
  ];

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width >= 768;

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
              const SizedBox(height: 28),
              const Text(
                'Versión completa y contacto',
                style: TextStyle(
                  color: AppTheme.primary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              for (final (label, url) in _links)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(label, style: const TextStyle(color: AppTheme.primary, fontSize: 14)),
                  trailing: Icon(AppIcons.broken(SolarIcons.ArrowRightUp), color: AppTheme.secondary, size: 18),
                  onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
