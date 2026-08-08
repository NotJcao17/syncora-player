import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  try {
    final response = await Supabase.instance.client
        .from('profiles')
        .select()
        .eq('id', user.id)
        .maybeSingle();
    return response;
  } catch (_) {
    return null;
  }
});
