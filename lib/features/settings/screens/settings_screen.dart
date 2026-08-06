import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../player/player_providers.dart';

/// Pantalla de Configuración (SettingsScreen calcada de settings.html mockup).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerState = ref.watch(playerStateProvider);
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
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
          // Tarjeta Perfil
          _buildCard(
            child: Row(
              children: [
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(32),
                      child: SizedBox(
                        width: 64,
                        height: 64,
                        child: CachedNetworkImage(
                          imageUrl: 'https://images.unsplash.com/photo-1534528741775-53994a69daeb?q=80&w=300&auto=format&fit=crop',
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => Container(
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
                        child: Icon(AppIcons.broken(SolarIcons.Camera), color: AppTheme.background, size: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Alex Morgan',
                        style: TextStyle(
                          color: AppTheme.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Plan Premium',
                        style: TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: () => _showComingSoon(context),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.surfaceHover),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('Editar', style: TextStyle(color: AppTheme.primary)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          _buildSectionHeader('REPRODUCCIÓN'),
          const SizedBox(height: 8),

          _buildCard(
            child: Column(
              children: [
                _buildSwitchTile(
                  icon: AppIcons.broken(SolarIcons.Scissors),
                  title: 'Omitir silencios (Skip Silence)',
                  subtitle: 'Elimina partes en silencio al inicio y final',
                  value: playerState.isSkipSilence,
                  onChanged: (val) {
                    controller.setSkipSilence(val);
                    AppToast.show(
                      context,
                      message: val ? 'Skip Silence activado' : 'Skip Silence desactivado',
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

          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSwitchTile(
                  icon: AppIcons.broken(SolarIcons.WiFiRouter),
                  title: 'Descargar solo con Wi-Fi',
                  subtitle: 'Evita consumo de datos móviles',
                  value: true,
                  onChanged: (val) => _showComingSoon(context),
                ),
                const Divider(height: 24, color: AppTheme.surfaceHover),
                // Storage Bar
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Almacenamiento usado', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
                    Text('2.4 GB / 32 GB', style: TextStyle(color: AppTheme.secondary, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: const LinearProgressIndicator(
                    value: 0.18,
                    backgroundColor: AppTheme.surfaceHover,
                    color: AppTheme.primary,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 16),
                _buildActionTile(
                  icon: AppIcons.broken(SolarIcons.Server),
                  title: 'Borrar caché',
                  subtitle: 'Libera espacio en disco',
                  onTap: () => _showComingSoon(context),
                ),
              ],
            ),
          ),

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
