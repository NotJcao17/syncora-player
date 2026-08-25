import 'package:flutter/material.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';

/// Widget reusable para mostrar un estado de error (Error State).
class ErrorStateWidget extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String message;
  final String? retryLabel;
  final VoidCallback? onRetry;

  const ErrorStateWidget({
    super.key,
    this.icon,
    this.title = 'Ha ocurrido un error',
    required this.message,
    this.retryLabel,
    this.onRetry,
  });

  /// Convierte excepciones o mensajes de error técnicos a mensajes amigables y comprensibles.
  static String formatErrorMessage(
    Object? error, {
    String defaultMessage = 'Ocurrió un problema temporal. Intenta nuevamente.',
  }) {
    if (error == null) return defaultMessage;
    final str = error.toString().trim();
    if (str.isEmpty) return defaultMessage;

    final lower = str.toLowerCase();

    // Problemas de red o conectividad
    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('clientexception') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('timeout') ||
        lower.contains('sin conexión') ||
        lower.contains('no internet') ||
        lower.contains('network error') ||
        lower.contains('network_error')) {
      return 'No se pudo conectar con el servidor. Revisa tu conexión a internet.';
    }

    // Contenido no encontrado
    if (lower.contains('404') ||
        lower.contains('not found') ||
        lower.contains('notfound') ||
        lower.contains('no encontrado') ||
        lower.contains('no disponible')) {
      return 'No se encontró el contenido solicitado o no está disponible.';
    }

    // Errores de permisos / 403 / 401
    if (lower.contains('403') ||
        lower.contains('forbidden') ||
        lower.contains('unauthorized') ||
        lower.contains('401')) {
      return 'Esta canción o contenido no está disponible en este momento.';
    }

    // Rate limiting
    if (lower.contains('429') ||
        lower.contains('rate limit') ||
        lower.contains('rate-limit') ||
        lower.contains('too many requests')) {
      return 'Demasiadas solicitudes. Por favor, espera un momento e intenta nuevamente.';
    }

    // Limpiar prefijos genéricos de excepciones Dart
    var cleaned = str;
    if (cleaned.startsWith('Exception: ')) {
      cleaned = cleaned.substring('Exception: '.length).trim();
    } else if (cleaned.startsWith('Error: ')) {
      cleaned = cleaned.substring('Error: '.length).trim();
    } else if (cleaned.startsWith('AuthException: ')) {
      cleaned = cleaned.substring('AuthException: '.length).trim();
    }

    // Si el texto contiene stack traces, JSONs o referencias a código fuente
    if (cleaned.contains('dart:') ||
        cleaned.contains('package:') ||
        cleaned.contains('#0 ') ||
        (cleaned.contains('{') && cleaned.contains('}'))) {
      return defaultMessage;
    }

    return cleaned.isNotEmpty ? cleaned : defaultMessage;
  }

  @override
  Widget build(BuildContext context) {
    final displayMessage = formatErrorMessage(message);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.1),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.redAccent.withValues(alpha: 0.3),
                  width: 1.5,
                ),
              ),
              child: Icon(
                icon ?? AppIcons.broken(SolarIcons.DangerTriangle),
                size: 48,
                color: Colors.redAccent,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              displayMessage,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.secondary,
                  ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: Icon(AppIcons.broken(SolarIcons.Refresh), size: 18),
                label: Text(retryLabel ?? 'Reintentar'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.surfaceActive,
                  foregroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
