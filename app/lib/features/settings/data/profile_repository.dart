import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final profileRepositoryProvider = Provider<ProfileRepository>((ref) => ProfileRepository(Supabase.instance.client));

class ProfileRepository {
  ProfileRepository(this._client);

  final SupabaseClient _client;

  /// 'en' or 'tw': the language the assistant speaks with this user.
  Future<void> setPreferredLanguage(String language) =>
      _client.rpc('update_my_profile', params: {'p_preferred_language': language});
}
