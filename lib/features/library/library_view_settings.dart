import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/app_settings_store.dart';
import '../../data/local_db/syncora_database.dart';

/// Criterios de orden de la biblioteca (ronda 3, D1).
enum LibrarySort {
  recientesEscuchadas('Escuchadas recientemente'),
  recientesAgregadas('Agregadas recientemente'),
  alfabetico('Alfabético');

  const LibrarySort(this.label);
  final String label;
}

/// Ronda 4: orden y forma de la biblioteca persistidos por dispositivo, igual
/// que el resto de ajustes. Antes vivían en el `State` de la pantalla y se
/// perdían al reiniciar la app.
const _librarySortKey = 'library.sort';
const _libraryGridViewKey = 'library.grid_view';

class LibrarySortNotifier extends Notifier<LibrarySort> {
  @override
  LibrarySort build() {
    final stored = ref.watch(appSettingsStoreProvider).getString(_librarySortKey);
    return LibrarySort.values.firstWhere(
      (v) => v.name == stored,
      orElse: () => LibrarySort.recientesEscuchadas,
    );
  }

  void set(LibrarySort value) {
    state = value;
    ref.read(appSettingsStoreProvider).setString(_librarySortKey, value.name);
  }
}

final librarySortProvider = NotifierProvider<LibrarySortNotifier, LibrarySort>(LibrarySortNotifier.new);

final libraryGridViewProvider = NotifierProvider<BoolSettingNotifier, bool>(
  () => BoolSettingNotifier(_libraryGridViewKey, false),
);

/// Orden de playlists compartido por Biblioteca y la barra lateral de
/// escritorio. Las fijadas van SIEMPRE primero: fijar es una decisión
/// explícita del usuario y no debe perderse por cambiar de orden. Dentro de
/// cada bloque manda [sort]. "Tus me gusta" y "On Repeat" no tienen trato
/// especial (ronda 4): se ordenan como cualquier otra.
List<Playlist> sortPlaylists(List<Playlist> input, LibrarySort sort) {
  final list = List<Playlist>.from(input);
  list.sort((a, b) {
    if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
    switch (sort) {
      case LibrarySort.recientesEscuchadas:
        final aAt = a.lastPlayedAt;
        final bAt = b.lastPlayedAt;
        // Nunca reproducidas al final, y entre ellas por fecha de creación.
        if (aAt == null && bAt == null) return b.createdAt.compareTo(a.createdAt);
        if (aAt == null) return 1;
        if (bAt == null) return -1;
        return bAt.compareTo(aAt);
      case LibrarySort.recientesAgregadas:
        return b.createdAt.compareTo(a.createdAt);
      case LibrarySort.alfabetico:
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }
  });
  return list;
}
