import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../utils/connectivity_service.dart';

class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key});

  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner> {
  @override

  Widget build(BuildContext context) {
    final isConnectedAsync = ref.watch(isConnectedProvider);
    final isConnected = isConnectedAsync.value ?? true;

    ref.listen<AsyncValue<bool>>(isConnectedProvider, (previous, next) {
      final prevVal = previous?.value ?? true;
      final nextVal = next.value ?? true;

      if (!prevVal && nextVal) {
        // Conexión restaurada
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Conexión restaurada'),
              duration: Duration(seconds: 2),
              backgroundColor: AppTheme.surfaceActive,
            ),
          );
        }
      }
    });

    final isOffline = !isConnected;

    return AnimatedSlide(
      offset: isOffline ? Offset.zero : const Offset(0, 1.5),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: isOffline ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2633),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFF59E0B),
              width: 1,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.broken(SolarIcons.WiFiRouter),
                color: const Color(0xFFF59E0B),
                size: 14,
              ),

              const SizedBox(width: 8),
              const Text(
                'Sin conexión',
                style: TextStyle(
                  color: AppTheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
