import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'deezer_api.dart';

final deezerApiProvider = Provider<DeezerApi>((ref) {
  return DeezerApi();
});
