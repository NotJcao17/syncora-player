import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/models/deezer/deezer_track.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';

/// Fase 7.F.2 -- pasos de UI compartidos entre los flujos de "vista previa
/// de sugerencias de IA" (7.F.1 "Crear playlist con IA" y 7.F.2 "Crear cola
/// con IA", y potencialmente 7.F.3 más adelante). Antes de esta extracción
/// 7.F.1 tenía su propia copia inline de cada uno de estos widgets -- ahora
/// ambos flujos usan literalmente el mismo código, igual que ya se hizo con
/// `PlaylistImportExportService.createPlaylistWithMatchedTracks` (D-8) para
/// evitar que diverjan.

/// Paso "generando con IA": ícono `StarsMinimalistic` en su variante *bold*
/// (D-14: mientras una generación está en curso) + spinner + [label].
class AiGeneratingIndicator extends StatelessWidget {
  final String label;

  const AiGeneratingIndicator({
    super.key,
    this.label = 'Generando sugerencias con IA...',
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 260,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.bold(SolarIcons.StarsMinimalistic), color: AppTheme.primary, size: 40),
            const SizedBox(height: 16),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: AppTheme.primary),
            ),
            const SizedBox(height: 16),
            Text(label, style: const TextStyle(color: AppTheme.secondary, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// Paso "matcheando contra Deezer": barra de progreso + "pista N de total" +
/// nombre de la pista que se está buscando ahora mismo.
class AiMatchingProgress extends StatelessWidget {
  final int current;
  final int total;
  final String currentTrackName;
  final String title;

  const AiMatchingProgress({
    super.key,
    required this.current,
    required this.total,
    this.currentTrackName = '',
    this.title = 'Buscando canciones...',
  });

  @override
  Widget build(BuildContext context) {
    final effectiveTotal = total <= 0 ? 1 : total;
    final effectiveCurrent = current.clamp(0, effectiveTotal);
    final ratio = (effectiveCurrent / effectiveTotal).clamp(0.0, 1.0);
    return SizedBox(
      height: 180,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio > 0 ? ratio : null,
                minHeight: 6,
                backgroundColor: AppTheme.surfaceHover,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Buscando canciones ($effectiveCurrent de $effectiveTotal)...',
              style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lista de pistas ya matcheadas contra Deezer con +/- por canción (edición
/// local, sin costo -- D-4/7.F.1). [excludedTrackIds] son los ids ya
/// excluidos por el usuario; [onToggle] alterna la exclusión de una pista.
class AiMatchedTrackList extends StatelessWidget {
  final List<DeezerTrack> tracks;
  final Set<int> excludedTrackIds;
  final ValueChanged<DeezerTrack> onToggle;

  const AiMatchedTrackList({
    super.key,
    required this.tracks,
    required this.excludedTrackIds,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final excluded = excludedTrackIds.contains(track.id);
        return Opacity(
          opacity: excluded ? 0.4 : 1.0,
          child: ListTile(
            dense: true,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 44,
                height: 44,
                child: track.coverUrl.isNotEmpty
                    ? CachedNetworkImage(imageUrl: track.coverUrl, fit: BoxFit.cover)
                    : Container(color: AppTheme.surfaceHover),
              ),
            ),
            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: Text(track.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.secondary, fontSize: 12)),
            trailing: IconButton(
              icon: Icon(
                AppIcons.broken(excluded ? SolarIcons.AddCircle : SolarIcons.CloseCircle),
                color: excluded ? Colors.greenAccent : Colors.redAccent,
                size: 20,
              ),
              onPressed: () => onToggle(track),
            ),
          ),
        );
      },
    );
  }
}

/// Sección colapsable "N sugerencias no se encontraron en Deezer" -- estado
/// de abierto/cerrado propio (no necesita que el padre lo administre).
/// [labels] ya viene formateado como texto por entrada (ej.
/// `RawImportTrack.toString()`) para no acoplar este widget compartido al
/// tipo del importador CSV/TXT.
class AiUnmatchedSuggestionsSection extends StatefulWidget {
  final List<String> labels;

  const AiUnmatchedSuggestionsSection({super.key, required this.labels});

  @override
  State<AiUnmatchedSuggestionsSection> createState() => _AiUnmatchedSuggestionsSectionState();
}

class _AiUnmatchedSuggestionsSectionState extends State<AiUnmatchedSuggestionsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: [
                Icon(AppIcons.broken(SolarIcons.DangerTriangle), color: Colors.orangeAccent, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${widget.labels.length} sugerencias no se encontraron en Deezer',
                    style: const TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(AppIcons.broken(_expanded ? SolarIcons.AltArrowUp : SolarIcons.AltArrowDown), color: AppTheme.secondary, size: 16),
              ],
            ),
          ),
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.labels.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    widget.labels[i],
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
