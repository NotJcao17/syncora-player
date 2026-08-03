import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Cargar variables de entorno
  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {
    // Si no se encuentra .env, continua con vars vacias o por defecto
  }

  // Init sqflite_common_ffi en Windows (Pitfall #9 — CRÍTICO)
  if (!kIsWeb && Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Init Supabase
  final rawUrl = dotenv.env['SUPABASE_URL'] ?? '';
  final rawKey = dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  final validUrl = (rawUrl.isNotEmpty &&
          rawUrl != 'tu_url_aqui' &&
          Uri.tryParse(rawUrl)?.hasAbsolutePath == true)
      ? rawUrl
      : 'https://placeholder.supabase.co';

  final validKey = (rawKey.isNotEmpty && rawKey != 'tu_anon_key_aqui')
      ? rawKey
      : 'placeholder-anon-key';

  await Supabase.initialize(
    url: validUrl,
    publishableKey: validKey,
  );

  // MediaKit y SMTCWindows solo se inicializan en Windows
  if (!kIsWeb && Platform.isWindows) {
    MediaKit.ensureInitialized();
    await SMTCWindows.initialize();
  }

  runApp(
    const ProviderScope(
      child: SyncoraApp(),
    ),
  );
}
