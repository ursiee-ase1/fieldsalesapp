import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final companyRepositoryProvider = Provider<CompanyRepository>(
  (ref) => CompanyRepository(Supabase.instance.client),
);

class CompanyRepository {
  CompanyRepository(this._client);

  final SupabaseClient _client;

  /// Creates the company and makes the signed-in user its administrator.
  Future<String> createCompany({required String name, required String adminFullName, String? phone}) async {
    final id = await _client.rpc('create_company', params: {
      'p_name': name.trim(),
      'p_full_name': adminFullName.trim(),
      'p_phone': (phone == null || phone.trim().isEmpty) ? null : phone.trim(),
    });
    return id as String;
  }
}
