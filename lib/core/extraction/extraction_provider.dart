import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'extraction_service.dart';

final extractionServiceProvider = Provider<ExtractionService>((ref) {
  final isTestEnv = Platform.environment.containsKey('FLUTTER_TEST');
  if (kIsWeb || isTestEnv) {
    return ExtractionServiceMock();
  }
  final service = ExtractionServiceReal();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});
