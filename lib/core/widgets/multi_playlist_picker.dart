import 'package:flutter/material.dart';

import '../../data/local_db/syncora_database.dart';
import '../limits/app_limits.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import 'app_bottom_sheet.dart';
import 'playlist_cover_widget.dart';

/// "Agregar a playlist" de una canción, con selección múltiple (como el
/// "Guardar en" de Spotify): se marcan una o varias playlists y se confirma
/// con un botón. Hoja deslizable en móvil y diálogo centrado en PC
/// (`AppBottomSheet.show`).
///
/// Las de [containingIds] (ya tienen la canción) salen marcadas y no se
/// pueden elegir: así no se crean duplicados sin querer.
///
/// [onCreate] crea una playlist nueva con ese nombre y la devuelve (o `null`
/// si no se pudo); la nueva aparece arriba, ya marcada.
///
/// Devuelve las playlists elegidas, o `null` si se cerró sin confirmar.
Future<List<Playlist>?> showMultiPlaylistPicker(
  BuildContext context, {
  required List<Playlist> playlists,
  Set<int> containingIds = const {},
  Future<Playlist?> Function(String title)? onCreate,
  String? trackTitle,
}) {
  return AppBottomSheet.show<List<Playlist>>(
    context: context,
    title: 'Agregar a playlist',
    maxHeightFactor: 0.9,
    child: MultiPlaylistPicker(
      playlists: playlists,
      containingIds: containingIds,
      onCreate: onCreate,
      trackTitle: trackTitle,
    ),
  );
}

class MultiPlaylistPicker extends StatefulWidget {
  const MultiPlaylistPicker({
    super.key,
    required this.playlists,
    this.onDone,
    this.containingIds = const {},
    this.onCreate,
    this.trackTitle,
  });

  final List<Playlist> playlists;
  final Set<int> containingIds;
  final Future<Playlist?> Function(String title)? onCreate;
  final String? trackTitle;

  /// Se llama con las elegidas al confirmar. Sin él, el selector cierra su
  /// propia ruta (hoja o diálogo) devolviéndolas.
  final void Function(List<Playlist> selected)? onDone;

  /// A partir de cuántas playlists se muestra el buscador.
  static const int searchThreshold = 7;

  @override
  State<MultiPlaylistPicker> createState() => _MultiPlaylistPickerState();
}

class _MultiPlaylistPickerState extends State<MultiPlaylistPicker> {
  late final List<Playlist> _playlists = List.of(widget.playlists);
  final Set<int> _selected = {};
  final TextEditingController _search = TextEditingController();
  final TextEditingController _newName = TextEditingController();
  String _query = '';
  bool _creating = false;
  bool _savingNew = false;

  @override
  void dispose() {
    _search.dispose();
    _newName.dispose();
    super.dispose();
  }

  List<Playlist> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _playlists;
    return _playlists.where((p) => p.title.toLowerCase().contains(q)).toList();
  }

  void _toggle(Playlist pl) {
    if (widget.containingIds.contains(pl.id)) return;
    setState(() {
      if (!_selected.remove(pl.id)) _selected.add(pl.id);
    });
  }

  Future<void> _createNew() async {
    final name = _newName.text.trim();
    final onCreate = widget.onCreate;
    if (name.isEmpty || onCreate == null || _savingNew) return;
    setState(() => _savingNew = true);
    final created = await onCreate(name);
    if (!mounted) return;
    setState(() {
      _savingNew = false;
      if (created != null) {
        _playlists.insert(0, created);
        _selected.add(created.id);
        _creating = false;
        _newName.clear();
        _search.clear();
        _query = '';
      }
    });
  }

  void _confirm() {
    if (_selected.isEmpty) return;
    final chosen = [for (final p in _playlists) if (_selected.contains(p.id)) p];
    final onDone = widget.onDone;
    if (onDone != null) {
      onDone(chosen);
    } else {
      // El contexto propio: en PC el diálogo vive en el navegador raíz y en
      // móvil la hoja en el del shell; el de quien lo abrió podría ser otro.
      Navigator.of(context).pop(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final count = _selected.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.trackTitle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              widget.trackTitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
            ),
          ),
        if (widget.playlists.length >= MultiPlaylistPicker.searchThreshold)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(color: AppTheme.primary, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Buscar playlist',
                hintStyle: const TextStyle(color: AppTheme.muted),
                prefixIcon: Icon(AppIcons.broken(SolarIcons.Magnifer), color: AppTheme.muted, size: 18),
                filled: true,
                fillColor: AppTheme.surfaceHover,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
          ),
        if (widget.onCreate != null) _buildNewPlaylistRow(),
        Flexible(
          child: visible.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                  child: Text(
                    _playlists.isEmpty ? 'Aún no tienes playlists. Crea una aquí arriba.' : 'Ninguna playlist coincide',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.secondary),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: visible.length,
                  itemBuilder: (c, i) => _buildRow(visible[i]),
                ),
        ),
        const Divider(height: 1, color: AppTheme.surfaceHover),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: SizedBox(
            height: 46,
            child: ElevatedButton(
              key: const Key('multi_playlist_picker_confirm'),
              onPressed: count == 0 ? null : _confirm,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: AppTheme.background,
                disabledBackgroundColor: AppTheme.surfaceActive,
                disabledForegroundColor: AppTheme.muted,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
              ),
              child: Text(
                count <= 1 ? 'Agregar' : 'Agregar a $count playlists',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNewPlaylistRow() {
    if (!_creating) {
      return ListTile(
        key: const Key('multi_playlist_picker_new'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: AppTheme.surfaceHover, borderRadius: BorderRadius.circular(6)),
          child: Icon(AppIcons.broken(SolarIcons.AddCircle), color: AppTheme.primary, size: 22),
        ),
        title: const Text('Nueva playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 14)),
        onTap: () => setState(() => _creating = true),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('multi_playlist_picker_new_name'),
              controller: _newName,
              autofocus: true,
              maxLength: AppLimits.playlistTitleMax,
              buildCounter: AppLimits.quietCounter,
              onSubmitted: (_) => _createNew(),
              style: const TextStyle(color: AppTheme.primary),
              decoration: const InputDecoration(
                hintText: 'Nombre de la playlist',
                hintStyle: TextStyle(color: AppTheme.muted),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.surfaceHover)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.primary)),
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _creating = false;
              _newName.clear();
            }),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          TextButton(
            key: const Key('multi_playlist_picker_create'),
            onPressed: _savingNew ? null : _createNew,
            child: _savingNew
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary))
                : const Text('Crear', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(Playlist pl) {
    final already = widget.containingIds.contains(pl.id);
    final selected = _selected.contains(pl.id);
    final Widget mark;
    if (already) {
      mark = Icon(AppIcons.bold(SolarIcons.CheckCircle), color: AppTheme.muted, size: 24);
    } else if (selected) {
      mark = Icon(AppIcons.bold(SolarIcons.CheckCircle), color: AppTheme.primary, size: 24);
    } else {
      mark = Container(
        width: 22,
        height: 22,
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppTheme.muted, width: 1.5)),
      );
    }
    return ListTile(
      key: ValueKey('multi_playlist_picker_${pl.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      horizontalTitleGap: 12,
      onTap: already ? null : () => _toggle(pl),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: PlaylistCoverWidget(
          playlistId: pl.id,
          coverUrl: pl.coverUrl,
          isLiked: pl.isLiked,
          isGenerated: pl.isGenerated,
          width: 44,
          height: 44,
          borderRadius: BorderRadius.circular(6),
          memCacheWidth: 96,
          memCacheHeight: 96,
        ),
      ),
      title: Text(
        pl.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: already ? AppTheme.secondary : AppTheme.primary,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
      subtitle: already
          ? const Text('Ya está en esta playlist', style: TextStyle(color: AppTheme.muted, fontSize: 12))
          : null,
      trailing: AnimatedSwitcher(duration: const Duration(milliseconds: 150), child: KeyedSubtree(key: ValueKey('$already$selected'), child: mark)),
    );
  }
}
