import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Carpetas de playlists en Supabase (Fase 8.E, migración 20).
class SupabaseFolderRepository {
  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  SupabaseClient? get _client {
    if (_isTestEnv) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchUserFolders() async {
    final client = _client;
    if (client == null) return [];
    final userId = client.auth.currentUser?.id;
    if (userId == null) return [];
    final response = await client.from('folders').select().eq('user_id', userId);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Crea la carpeta y devuelve su id remoto.
  Future<String> createFolder(String name) async {
    final client = _client;
    final userId = client?.auth.currentUser?.id;
    if (client == null || userId == null) throw StateError('Sin sesión');
    final row = await client
        .from('folders')
        .insert({'user_id': userId, 'name': name})
        .select('id')
        .single();
    return row['id'].toString();
  }

  Future<void> renameFolder(String id, String name) async {
    final client = _client;
    if (client == null) return;
    await client
        .from('folders')
        .update({'name': name, 'updated_at': DateTime.now().toIso8601String()})
        .eq('id', id);
  }

  /// Las playlists que contenía vuelven a la raíz (`ON DELETE SET NULL`).
  Future<void> deleteFolder(String id) async {
    final client = _client;
    if (client == null) return;
    await client.from('folders').delete().eq('id', id);
  }
}
