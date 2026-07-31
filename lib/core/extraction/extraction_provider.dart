import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'extraction_service.dart';

final extractionServiceProvider = Provider<ExtractionService>((ref) {
  if (kIsWeb) {
    return ExtractionServiceMock();
  }
  final service = ExtractionServiceReal();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});
