import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'lrclib_api.dart';

final lrcLibApiProvider = Provider<LRCLibApi>((ref) {
  return LRCLibApi();
});
