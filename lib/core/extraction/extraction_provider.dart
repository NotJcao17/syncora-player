import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'extraction_service.dart';

bool get _isTestEnv {
  try {
    final name = WidgetsBinding.instance.runtimeType.toString();
    return name.contains('Test') || name.contains('Automated');
  } catch (_) {
    return true;
  }
}

final extractionServiceProvider = Provider<ExtractionService>((ref) {
  if (kIsWeb || _isTestEnv) {
    return ExtractionServiceMock();
  }
  final service = ExtractionServiceReal();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});
