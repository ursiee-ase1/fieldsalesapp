import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/domain/models.dart';

class Member {
  const Member({
    required this.membershipId,
    required this.userId,
    required this.fullName,
    required this.role,
    required this.status,
    this.phone,
  });

  factory Member.fromJson(Map<String, dynamic> json) => Member(
        membershipId: json['membership_id'] as String,
        userId: json['user_id'] as String,
        fullName: json['full_name'] as String,
        phone: json['phone_e164'] as String?,
        role: MemberRole.parse(json['role'] as String),
        status: MemberStatus.parse(json['status'] as String),
      );

  final String membershipId;
  final String userId;
  final String fullName;
  final String? phone;
  final MemberRole role;
  final MemberStatus status;
}

class InviteRequest {
  const InviteRequest({
    required this.fullName,
    required this.role,
    required this.password,
    this.phone,
    this.email,
  });

  final String fullName;
  final MemberRole role;
  final String password;
  final String? phone;
  final String? email;

  Map<String, dynamic> toJson() => {
        'full_name': fullName,
        'role': role.name,
        'password': password,
        if (phone != null) 'phone': phone,
        if (email != null) 'email': email,
      };
}

final membersRepositoryProvider = Provider<MembersRepository>(
  (ref) => MembersRepository(Supabase.instance.client),
);

final membersProvider = FutureProvider.autoDispose<List<Member>>(
  (ref) => ref.watch(membersRepositoryProvider).list(),
);

class MembersRepository {
  MembersRepository(this._client);

  final SupabaseClient _client;

  Future<List<Member>> list() async {
    final data = await _client.rpc('list_members') as List<dynamic>;
    return data.map((row) => Member.fromJson(Map<String, dynamic>.from(row as Map))).toList();
  }

  /// Account creation needs the service role, so it runs in an Edge Function.
  Future<void> invite(InviteRequest request) =>
      _client.functions.invoke('invite-member', body: request.toJson());

  Future<void> setStatus(String membershipId, MemberStatus status) =>
      _client.rpc('update_member', params: {'p_membership': membershipId, 'p_status': status.name});
}
