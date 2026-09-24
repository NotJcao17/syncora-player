import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_toast.dart';
import '../player_providers.dart';
import '../sleep_timer.dart';

const _presetMinutes = [5, 15, 30, 45, 60];

/// Selector del temporizador de apagado: diálogo centrado en escritorio,
/// bottom sheet en móvil (lo decide [AppBottomSheet.show]).
Future<void> showSleepTimerPicker(BuildContext context) {
  return AppBottomSheet.show(
    context: context,
    title: 'Temporizador de apagado',
    child: _SleepTimerOptions(hostContext: context),
  );
}

class _SleepTimerOptions extends ConsumerWidget {
  const _SleepTimerOptions({required this.hostContext});

  /// Contexto de quien abrió el selector: el del propio sheet deja de estar
  /// montado al cerrarlo, y el aviso se muestra después.
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(sleepTimerProvider);
    final notifier = ref.read(sleepTimerProvider.notifier);
    final hasTrack = ref.watch(currentTrackProvider) != null;

    void choose(VoidCallback action, String message) {
      action();
      AppBottomSheet.pop(context);
      AppToast.show(hostContext, message: message);
    }

    return ListView(
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (timer.isActive)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                Icon(AppIcons.bold(SolarIcons.Moon), color: AppTheme.primary, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: SleepTimerStatusText(
                    style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        for (final minutes in _presetMinutes)
          _TimerOption(
            label: '$minutes minutos',
            onTap: () => choose(
              () => notifier.startTimed(Duration(minutes: minutes)),
              'La música se detendrá en $minutes minutos',
            ),
          ),
        if (hasTrack || timer.mode == SleepTimerMode.endOfTrack)
          _TimerOption(
          label: 'Al terminar la canción',
          selected: timer.mode == SleepTimerMode.endOfTrack,
          onTap: () => choose(notifier.startEndOfTrack, 'La música se detendrá al terminar esta canción'),
        ),
        if (timer.isActive)
          _TimerOption(
            label: 'Desactivar temporizador',
            color: Colors.redAccent,
            onTap: () => choose(notifier.cancel, 'Temporizador desactivado'),
          ),
      ],
    );
  }
}

class _TimerOption extends StatelessWidget {
  const _TimerOption({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.color = AppTheme.primary,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: color, fontSize: 15, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
              ),
            ),
            if (selected) Icon(AppIcons.bold(SolarIcons.CheckCircle), color: AppTheme.primary, size: 18),
          ],
        ),
      ),
    );
  }
}

/// Estado legible del temporizador ("Se detendrá en 14:32", "Al terminar la
/// canción", "Desactivado"), con la cuenta regresiva actualizada cada segundo.
class SleepTimerStatusText extends ConsumerStatefulWidget {
  const SleepTimerStatusText({super.key, this.style, this.offLabel = 'Desactivado'});

  final TextStyle? style;
  final String offLabel;

  @override
  ConsumerState<SleepTimerStatusText> createState() => _SleepTimerStatusTextState();
}

class _SleepTimerStatusTextState extends ConsumerState<SleepTimerStatusText> {
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker(bool needsTicker) {
    if (needsTicker && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needsTicker && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final timer = ref.watch(sleepTimerProvider);
    _syncTicker(timer.mode == SleepTimerMode.timed);

    final String text;
    switch (timer.mode) {
      case SleepTimerMode.off:
        text = widget.offLabel;
      case SleepTimerMode.endOfTrack:
        text = 'Se detendrá al terminar la canción';
      case SleepTimerMode.timed:
        var remaining = timer.endsAt!.difference(DateTime.now());
        if (remaining.isNegative) remaining = Duration.zero;
        final minutes = remaining.inMinutes;
        final seconds = (remaining.inSeconds % 60).toString().padLeft(2, '0');
        text = 'Se detendrá en $minutes:$seconds';
    }
    return Text(text, style: widget.style, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}
