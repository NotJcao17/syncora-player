import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/os_controls/windows_media_controls.dart';
import 'package:syncora_player/features/player/player_models.dart';

void main() {
  test('el título de la ventana enseña la canción y el artista', () {
    expect(
      WindowsMediaControls.windowTitleFor(const SyncoraTrack(id: '1', title: 'Yellow', artist: 'Coldplay')),
      'Yellow · Coldplay',
    );
  });

  test('sin artista, solo el título; sin canción, el nombre de la app', () {
    expect(WindowsMediaControls.windowTitleFor(const SyncoraTrack(id: '1', title: 'Yellow')), 'Yellow');
    expect(WindowsMediaControls.windowTitleFor(null), 'Syncora Player');
  });
}
