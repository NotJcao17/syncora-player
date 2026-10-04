import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final authStateProvider = StreamProvider<AuthState>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return const Stream.empty();
  }
  return Supabase.instance.client.auth.onAuthStateChange;
});

final currentUserProvider = Provider<User?>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return null;
  }
  final authState = ref.watch(authStateProvider);
  return authState.value?.session?.user ?? Supabase.instance.client.auth.currentUser;
});

final profileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return null;
  }
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  // Último perfil leído, por usuario. Sin él, un arranque sin red (o con la
  // sesión todavía refrescándose) dejaba el perfil en `null` toda la sesión:
  // la foto propia desaparecía y salía el DiceBear de la semilla por defecto.
  final cacheKey = 'profile_cache_${user.id}';
  try {
    final response = await Supabase.instance.client
        .from('profiles')
        .select()
        .eq('id', user.id)
        .maybeSingle();
    if (response != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(cacheKey, jsonEncode(response));
      } catch (_) {}
    }
    return response;
  } catch (_) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(cacheKey);
      if (cached != null) return Map<String, dynamic>.from(jsonDecode(cached) as Map);
    } catch (_) {}
    return null;
  }
});
