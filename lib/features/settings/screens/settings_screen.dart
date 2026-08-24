import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/cache/cover_cache_service.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/services/ai_key_storage.dart';
import '../../auth/auth_provider.dart';
import '../../auth/local_mode_provider.dart';

import '../../download/download_provider.dart';
import '../../player/player_providers.dart';
import '../../profile/widgets/avatar_selector_sheet.dart';


/// Pantalla de Configuración (SettingsScreen)
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _openAvatarSelector(BuildContext context, WidgetRef ref, {required bool isLocalMode, required String currentSeed}) {
    AvatarSelectorSheet.show(
      context,
      currentSeed: currentSeed,
      // Fase 7.I.4: en modo local no hay tabla `profiles` donde
      // `AvatarSelectorSheet` pueda escribir el seed elegido (su propio
      // update a Supabase ya se salta solo, porque `userId` queda vacío
      // sin sesión) -- este callback es el único lugar que persiste la
      // elección en modo local.
      onAvatarSelected: isLocalMode
          ? (seed) async {
              await ref.read(localModeStorageProvider).setAvatarSeed(seed);
              ref.invalidate(localAvatarSeedProvider);
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final currentUser = ref.watch(currentUserProvider);
    final profileAsync = ref.watch(profileProvider);
    // Fase 7.I.9: sección de cuenta reemplazada por el bloque de "Modo
    // local" cuando aplica (D-24 -- el modo local es un estado de sesión,
    // no de red, así que se decide con este flag, no con `isConnected`).
    final isLocalMode = ref.watch(localModeProvider);
    final localSeedAsync = isLocalMode ? ref.watch(localAvatarSeedProvider) : null;

    final String seed = isLocalMode
        ? (localSeedAsync?.value ?? 'default-seed')
        : (profileAsync.value?['avatar_seed'] ?? currentUser?.id ?? 'default-seed');
    final String avatarUrl = 'https://api.dicebear.com/9.x/adventurer-neutral/svg?seed=$seed';
    final String userEmail = currentUser?.email ?? 'usuario@syncora.com';

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
          'Configuración',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppTheme.primary,
              ),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: isDesktop ? 32 : 20,
          vertical: 16,
        ),
        children: [
          if (isLocalMode) ...[
            _buildSectionHeader('MODO LOCAL'),
            const SizedBox(height: 8),
            _LocalModeSection(
              avatarUrl: avatarUrl,
              onEditAvatar: () => _openAvatarSelector(context, ref, isLocalMode: true, currentSeed: seed),
            ),
          ] else ...[
          _buildSectionHeader('MI CUENTA'),
          const SizedBox(height: 8),
          // Tarjeta Perfil
          _buildCard(
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => _openAvatarSelector(context, ref, isLocalMode: false, currentSeed: seed),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(32),
                        child: Container(
                          width: 64,
                          height: 64,
                          color: AppTheme.surfaceActive,
                          child: SvgPicture.network(
                            avatarUrl,
                            fit: BoxFit.cover,
                            placeholderBuilder: (_) => Container(
                              color: AppTheme.surfaceHover,
                              child: Icon(AppIcons.broken(SolarIcons.User), color: AppTheme.muted, size: 32),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: AppTheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(AppIcons.broken(SolarIcons.PenNewSquare), color: AppTheme.background, size: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        userEmail,
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Usuario Syncora',
                        style: TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: () => _openAvatarSelector(context, ref, isLocalMode: false, currentSeed: seed),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.surfaceHover),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('Avatar', style: TextStyle(color: AppTheme.primary)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          // Botón Cerrar Sesión
          _buildCard(
            child: InkWell(
              onTap: () async {
                try {
                  await Supabase.instance.client.auth.signOut();
                } catch (_) {}
                if (context.mounted) {
                  context.go('/auth');
                }
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(AppIcons.broken(SolarIcons.Logout), color: Colors.redAccent, size: 22),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Text(
                        'Cerrar sesión',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ],

          const SizedBox(height: 24),
          _buildSectionHeader('REPRODUCCIÓN'),
          const SizedBox(height: 8),

          _buildCard(
            child: Column(
              children: [
                // Función quitada por completo (decisión del usuario, pruebas
                // manuales post-Fase 7): en Windows, el filtro
                // `af=lavfi=[silencedetect...]` de libmpv rompía la
                // reproducción por completo al terminar la pista, incluso con
                // el guard de detección de fallo ya agregado -- dos intentos
                // de arreglo no lo resolvieron. Nunca se confirmó si Android
                // (mecanismo nativo de ExoPlayer, sin libmpv de por medio)
                // tenía el mismo problema o no, así que se sacó la opción
                // para las dos plataformas en vez de dejarla a medias. El
                // motor (`MediaKitEngine._applySilenceFilter`) ya es un no-op
                // seguro si algo llegara a invocarlo igual.
                Consumer(
                  builder: (context, ref, _) {
                    final radioEnabled = ref.watch(radioEnabledProvider);
                    return _buildSwitchTile(
                      icon: AppIcons.broken(SolarIcons.Radio),
                      title: 'Radio / cola infinita',
                      subtitle: 'Sigue añadiendo canciones parecidas cuando la cola se acorta',
                      value: radioEnabled,
                      onChanged: (val) {
                        ref.read(radioEnabledProvider.notifier).state = val;
                        AppToast.show(
                          context,
                          message: val ? 'Radio activada' : 'Radio desactivada',
                        );
                      },
                    );
                  },
                ),
                const Divider(height: 24, color: AppTheme.surfaceHover),
                Consumer(
                  builder: (context, ref, _) {
                    final crossfadeDuration = ref.watch(crossfadeDurationProvider);
                    return _buildCrossfadeSelector(
                      value: crossfadeDuration,
                      onChanged: (val) {
                        ref.read(crossfadeDurationProvider.notifier).state = val;
                        AppToast.show(
                          context,
                          message: val == Duration.zero
                              ? 'Crossfade desactivado'
                              : 'Crossfade: ${val.inSeconds}s',
                        );
                      },
                    );
                  },
                ),
                const Divider(height: 24, color: AppTheme.surfaceHover),
                _buildActionTile(
                  icon: AppIcons.broken(SolarIcons.Tuning),
                  title: 'Ecualizador',
                  subtitle: 'Ajusta las frecuencias de sonido',
                  onTap: () => _showComingSoon(context),
                ),
                const Divider(height: 24, color: AppTheme.surfaceHover),
                _buildActionTile(
                  icon: AppIcons.broken(SolarIcons.Moon),
                  title: 'Temporizador de apagado',
                  subtitle: 'Detener música automáticamente',
                  onTap: () => _showComingSoon(context),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          _buildSectionHeader('DESCARGA Y ALMACENAMIENTO'),

          const SizedBox(height: 8),

          Consumer(
            builder: (context, ref, _) {
              final wifiOnly = ref.watch(downloadWifiOnlyProvider);
              final downloadedTracksAsync = ref.watch(watchAllDownloadedTracksProvider);
              final coverCache = ref.watch(coverCacheServiceProvider);
              final dao = ref.watch(downloadedTrackDaoProvider);

              final downloadedTracks = downloadedTracksAsync.value ?? [];
              final audioBytes = downloadedTracks.fold<int>(0, (int sum, DownloadedTrack t) => sum + t.fileSizeBytes);

              final coverBytes = coverCache.currentSizeBytes;
              final totalMB = ((audioBytes + coverBytes) / (1024 * 1024)).toStringAsFixed(1);
              final audioMB = (audioBytes / (1024 * 1024)).toStringAsFixed(1);
              final coverMB = (coverBytes / (1024 * 1024)).toStringAsFixed(1);

              return _buildCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSwitchTile(
                      icon: AppIcons.broken(SolarIcons.WiFiRouter),
                      title: 'Descargar solo con Wi-Fi',
                      subtitle: 'Evita consumo de datos móviles',
                      value: wifiOnly,
                      onChanged: (val) {
                        ref.read(downloadWifiOnlyProvider.notifier).state = val;
                        AppToast.show(
                          context,
                          message: val ? 'Descargas restringidas a Wi-Fi' : 'Descargas permitidas con datos móviles',
                        );
                      },
                    ),
                    const Divider(height: 24, color: AppTheme.surfaceHover),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Almacenamiento usado', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
                        Text('$totalMB MB / Local', style: const TextStyle(color: AppTheme.secondary, fontSize: 13)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$audioMB MB audio  •  $coverMB MB portadas',
                      style: const TextStyle(color: AppTheme.secondary, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (audioBytes + coverBytes) / (500 * 1024 * 1024), // Max reference 500MB
                        backgroundColor: AppTheme.surfaceHover,
                        color: AppTheme.primary,
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildActionTile(
                      icon: AppIcons.broken(SolarIcons.Server),
                      title: 'Borrar caché de portadas',
                      subtitle: 'Libera $coverMB MB de imágenes',
                      onTap: () async {
                        await coverCache.clear();
                        if (context.mounted) {
                          AppToast.show(context, message: 'Caché de portadas borrada');
                        }
                      },
                    ),
                    const Divider(height: 24, color: AppTheme.surfaceHover),
                    _buildActionTile(
                      icon: AppIcons.broken(SolarIcons.TrashBinTrash),
                      title: 'Borrar todas las descargas',
                      subtitle: 'Libera $audioMB MB de audio (${downloadedTracks.length} canciones)',
                      onTap: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: AppTheme.surface,
                            title: const Text('¿Eliminar todas las descargas?', style: TextStyle(color: AppTheme.primary)),
                            content: const Text('Esta acción borrará todas las canciones descargadas de tu dispositivo.', style: TextStyle(color: AppTheme.secondary)),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Eliminar todo'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await dao.deleteAll();
                          if (context.mounted) {
                            AppToast.show(context, message: 'Todas las descargas han sido eliminadas');
                          }
                        }
                      },
                    ),
                  ],
                ),
              );
            },
          ),


          // Fase 7.I: las funciones de IA necesitan el JWT del usuario --
          // no funcionan sin cuenta (D-24), la sección entera se oculta.
          if (!isLocalMode) ...[
            const SizedBox(height: 24),
            _buildSectionHeader('INTELIGENCIA ARTIFICIAL'),
            const SizedBox(height: 8),
            _buildCard(child: const _AiByokSection()),
          ],

          const SizedBox(height: 24),
          _buildSectionHeader('ACERCA DE'),
          const SizedBox(height: 8),

          _buildCard(
            child: Row(
              children: [
                Icon(AppIcons.broken(SolarIcons.InfoCircle), color: AppTheme.primary, size: 22),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Syncora Player v1.0.0',
                        style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '100% Gratuito, Privado y Resiliente',
                        style: TextStyle(color: AppTheme.secondary, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.surfaceShadow,
      ),
      child: child,
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: AppTheme.secondary,
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.primary, size: 22),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: AppTheme.secondary, fontSize: 12)),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: AppTheme.primary,
          activeThumbColor: AppTheme.background,
        ),
      ],
    );
  }

  /// Selector de duración de crossfade (Fase 7.D.5): off / 2s / 4s / 6s.
  /// No hay un patrón de selector múltiple ya existente en esta pantalla
  /// (solo `_buildSwitchTile`, on/off) — se sigue el mismo estilo visual
  /// (icono + título + subtítulo a la izquierda) con una fila de píldoras a
  /// la derecha en vez de un `Switch`.
  Widget _buildCrossfadeSelector({
    required Duration value,
    required ValueChanged<Duration> onChanged,
  }) {
    const options = [
      Duration.zero,
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 6),
    ];

    String labelFor(Duration d) => d == Duration.zero ? 'Off' : '${d.inSeconds}s';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(AppIcons.broken(SolarIcons.Soundwave), color: AppTheme.primary, size: 22),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Crossfade',
                style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const SizedBox(height: 2),
              const Text(
                'Transición suave entre canciones descargadas',
                style: TextStyle(color: AppTheme.secondary, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: options.map((option) {
                  final selected = option == value;
                  return GestureDetector(
                    onTap: () => onChanged(option),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? AppTheme.primary : AppTheme.surfaceActive,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        labelFor(option),
                        style: TextStyle(
                          color: selected ? AppTheme.background : AppTheme.secondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.primary, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(color: AppTheme.secondary, fontSize: 12)),
                ],
              ),
            ),
            Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary, size: 18),
          ],
        ),
      ),
    );
  }

  void _showComingSoon(BuildContext context) {
    AppToast.show(context, message: 'Próximamente');
  }
}

/// Fase 7.I.9 -- reemplaza la sección "MI CUENTA" cuando el usuario está en
/// modo local (D-23/D-24): explica el estado sin esconderlo como letra
/// chica (mismo texto honesto que ya usa el botón "Usar sin cuenta" de
/// `auth_screen.dart`), y ofrece "Crear cuenta y subir mi biblioteca"
/// (7.I.10) y la mención de exportar CSV como respaldo (7.I.11 -- el botón
/// real ya existe en cada playlist, `playlist_detail_screen.dart`, esto
/// solo le da visibilidad para quien está en modo local).
class _LocalModeSection extends StatelessWidget {
  final String avatarUrl;
  final VoidCallback onEditAvatar;

  const _LocalModeSection({required this.avatarUrl, required this.onEditAvatar});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: AppTheme.surfaceShadow,
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: onEditAvatar,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Container(
                    width: 64,
                    height: 64,
                    color: AppTheme.surfaceActive,
                    child: SvgPicture.network(
                      avatarUrl,
                      fit: BoxFit.cover,
                      placeholderBuilder: (_) => Container(
                        color: AppTheme.surfaceHover,
                        child: Icon(AppIcons.broken(SolarIcons.User), color: AppTheme.muted, size: 32),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Modo local', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                    SizedBox(height: 2),
                    Text('Sin cuenta en la nube', style: TextStyle(color: AppTheme.secondary, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0x26F59E0B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
          ),
          child: const Text(
            'Tu biblioteca se guarda solo en este dispositivo. No hay sincronización entre dispositivos '
            'ni respaldo en la nube. Si pierdes el dispositivo, pierdes tu biblioteca -- exporta tus '
            'playlists a CSV (botón "Exportar" en cada una) como respaldo mientras tanto.',
            style: TextStyle(color: Color(0xFFFBBF24), fontSize: 12, fontWeight: FontWeight.w500, height: 1.4),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: AppTheme.surfaceShadow,
          ),
          child: InkWell(
            onTap: () => context.push('/auth'),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(AppIcons.broken(SolarIcons.CloudUpload), color: AppTheme.primary, size: 22),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Crear cuenta y subir mi biblioteca',
                        style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Sube tus playlists locales a la nube (si hay cupo disponible)',
                        style: TextStyle(color: AppTheme.secondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Icon(AppIcons.broken(SolarIcons.AltArrowRight), color: AppTheme.secondary, size: 18),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Fase 7.E.8 -- UI de BYOK ("Bring Your Own Key") para las funciones de IA
/// de la Fase 7.F. Campo para pegar la llave propia de Gemini (guardada en
/// `flutter_secure_storage` vía [AiKeyStorage], nunca en un provider en
/// memoria plano ni en la BD -- Documento Maestro §4.3 punto 3), botón para
/// borrarla, y una explicación breve de qué implica.
class _AiByokSection extends ConsumerStatefulWidget {
  const _AiByokSection();

  @override
  ConsumerState<_AiByokSection> createState() => _AiByokSectionState();
}

class _AiByokSectionState extends ConsumerState<_AiByokSection> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(aiKeyStorageProvider).setKey(value);
      _controller.clear();
      ref.invalidate(aiByokKeyPresentProvider);
      if (mounted) {
        AppToast.show(context, message: 'Llave de Gemini guardada en este dispositivo');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      await ref.read(aiKeyStorageProvider).deleteKey();
      ref.invalidate(aiByokKeyPresentProvider);
      if (mounted) {
        AppToast.show(context, message: 'Llave de Gemini borrada');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openGeminiKeyPage() async {
    final uri = Uri.parse('https://aistudio.google.com/apikey');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        AppToast.show(context, message: 'No se pudo abrir el enlace');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasKeyAsync = ref.watch(aiByokKeyPresentProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(AppIcons.broken(SolarIcons.StarsMinimalistic), color: AppTheme.primary, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tu propia llave de Gemini',
                    style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Las funciones de IA de Syncora usan una cuota gratuita compartida entre toda la app. '
                    'Si traes tu propia llave gratuita de Gemini, tus peticiones dejan de contar contra ese '
                    'límite compartido. La llave nunca sale de este dispositivo, salvo hacia la función de IA '
                    'en cada petición -- nunca se guarda en la nube ni en ningún otro lado.',
                    style: TextStyle(color: AppTheme.secondary, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        hasKeyAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary),
            ),
          ),
          error: (_, _) => const Text(
            'No se pudo leer el almacenamiento seguro del dispositivo',
            style: TextStyle(color: AppTheme.secondary, fontSize: 12),
          ),
          data: (hasKey) {
            if (hasKey) {
              return Row(
                children: [
                  Icon(AppIcons.broken(SolarIcons.CheckCircle), color: Colors.greenAccent, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Llave guardada en este dispositivo',
                      style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _delete,
                    child: const Text('Borrar', style: TextStyle(color: Colors.redAccent)),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _controller,
                  obscureText: _obscure,
                  style: const TextStyle(color: AppTheme.primary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Pega tu API key de Gemini',
                    hintStyle: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                    filled: true,
                    fillColor: AppTheme.surfaceActive,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        AppIcons.broken(_obscure ? SolarIcons.Eye : SolarIcons.EyeClosed),
                        color: AppTheme.secondary,
                        size: 18,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: _busy ? null : _openGeminiKeyPage,
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      child: const Text('Consigue una llave gratuita', style: TextStyle(color: AppTheme.primary, fontSize: 12)),
                    ),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: _busy ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                      child: Text('Guardar', style: TextStyle(color: AppTheme.background)),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
