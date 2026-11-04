import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class Customer {
  const Customer({
    required this.id,
    required this.fullName,
    required this.consentGiven,
    required this.version,
    required this.openFollowUps,
    this.phone,
    this.location,
    this.notes,
    this.assignedAgentId,
    this.lastInteractionAt,
    this.nextFollowUp,
  });

  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: j['id'] as String,
        fullName: j['full_name'] as String,
        phone: j['phone_e164'] as String?,
        location: j['location_text'] as String?,
        notes: j['notes'] as String?,
        consentGiven: j['consent_given'] as bool,
        version: j['version'] as int,
        assignedAgentId: j['assigned_agent_id'] as String?,
        lastInteractionAt: j['last_interaction_at'] == null ? null : DateTime.parse(j['last_interaction_at'] as String),
        openFollowUps: j['open_follow_ups'] as int,
        nextFollowUp: j['next_follow_up'] == null ? null : DateTime.parse(j['next_follow_up'] as String),
      );

  final String id;
  final String fullName;
  final String? phone;
  final String? location;
  final String? notes;
  final bool consentGiven;
  final int version;
  final String? assignedAgentId;
  final DateTime? lastInteractionAt;
  final int openFollowUps;
  final DateTime? nextFollowUp;
}

class MatchReview {
  const MatchReview({
    required this.id,
    required this.newName,
    required this.candidateName,
    this.createdByName,
    this.phone,
  });

  factory MatchReview.fromJson(Map<String, dynamic> j) => MatchReview(
        id: j['id'] as String,
        newName: j['new_name'] as String,
        candidateName: j['candidate_name'] as String,
        createdByName: j['new_created_by'] as String?,
        phone: j['phone_e164'] as String?,
      );

  final String id;
  final String newName;
  final String candidateName;
  final String? createdByName;
  final String? phone;
}

final customersRepositoryProvider = Provider<CustomersRepository>(
  (ref) => CustomersRepository(Supabase.instance.client),
);

final customerSearchProvider = NotifierProvider<CustomerSearch, String>(CustomerSearch.new);

class CustomerSearch extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

final customersProvider = FutureProvider.autoDispose<List<Customer>>(
  (ref) => ref.watch(customersRepositoryProvider).list(ref.watch(customerSearchProvider)),
);

final matchReviewsProvider = FutureProvider.autoDispose<List<MatchReview>>(
  (ref) => ref.watch(customersRepositoryProvider).matchReviews(),
);

class CustomersRepository {
  CustomersRepository(this._client);

  final SupabaseClient _client;

  /// The server applies the role's visibility rule (agents see only their customers).
  Future<List<Customer>> list(String search) async {
    final rows = await _client.rpc('list_customers', params: {'p_search': search.trim().isEmpty ? null : search.trim()})
        as List;
    return [for (final r in rows) Customer.fromJson(Map<String, dynamic>.from(r as Map))];
  }

  Future<List<MatchReview>> matchReviews() async {
    final rows = await _client.rpc('list_match_reviews') as List;
    return [for (final r in rows) MatchReview.fromJson(Map<String, dynamic>.from(r as Map))];
  }

  Future<void> resolveMatch(String reviewId, {required bool same}) =>
      _client.rpc('resolve_customer_match', params: {'p_review_id': reviewId, 'p_same': same});

  Future<void> update(Customer c,
          {required String fullName, String? phone, String? location, String? notes, required bool consent}) =>
      _client.rpc('update_customer', params: {
        'p_id': c.id,
        'p_expected_version': c.version,
        'p_full_name': fullName,
        'p_phone': phone,
        'p_location': location,
        'p_notes': notes,
        'p_consent': consent,
        'p_assigned_agent_id': c.assignedAgentId,
      });
}
