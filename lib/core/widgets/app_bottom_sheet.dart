import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Modal Bottom Sheet personalizado con fondo sólido #1E2633 y handle bar.
class AppBottomSheet extends StatelessWidget {
  final String? title;
  final Widget child;
  final double maxHeightFactor;

  const AppBottomSheet({
    super.key,
    this.title,
    required this.child,
    this.maxHeightFactor = 0.85,
  });

  static Future<T?> show<T>({
    required BuildContext context,
    required Widget child,
    String? title,
    double maxHeightFactor = 0.85,
  }) {
    final isDesktop = MediaQuery.of(context).size.width >= 720;
    if (isDesktop) {
      return showDialog<T>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null) ...[
                  Text(
                    title,
                    style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),

                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppTheme.surfaceHover),
                  const SizedBox(height: 12),
                ],
                Flexible(child: child),
              ],
            ),
          ),
        ),
      );
    }

    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AppBottomSheet(
        title: title,
        maxHeightFactor: maxHeightFactor,
        child: child,
      ),
    );
  }

  static void pop(BuildContext context) {
    if (!context.mounted) return;
    try {
      final isDesktop = MediaQuery.of(context).size.width >= 720;
      if (isDesktop) {
        Navigator.of(context, rootNavigator: true).pop();
      } else {
        if (Navigator.canPop(context)) {
          Navigator.of(context).pop();
        }
      }
    } catch (_) {
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    }
  }



  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * maxHeightFactor;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: AppTheme.surfaceUpShadow,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle Bar
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.muted.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (title != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Text(
                  title!,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              const Divider(height: 1, color: AppTheme.surfaceHover),
            ],
            Flexible(
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}
