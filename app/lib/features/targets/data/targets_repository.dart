import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format.dart';

enum TargetScope { company, agent }

enum TargetMetric {
  units('Items sold'),
  amount('Amount collected (GH₵)');

  const TargetMetric(this.label);
  final String label;
}

class DailyTarget {
  const DailyTarget({
    required this.id,
    required this.scope,
    required this.metric,
    required this.value,
    required this.effectiveFrom,
    this.agentName,
    this.teamName,
    this.productName,
  });

  factory DailyTarget.fromJson(Map<String, dynamic> j) => DailyTarget(
        id: j['id'] as String,
        scope: j['scope'] as String,
        agentName: j['agent_name'] as String?,
        teamName: j['team_name'] as String?,
        productName: j['product_name'] as String?,
        metric: j['metric'] == 'amount' ? TargetMetric.amount : TargetMetric.units,
        value: asNum(j['value']),
        effectiveFrom: DateTime.parse(j['effective_from'] as String),
      );

  final String id;
  final String scope;
  final String? agentName;
  final String? teamName;
  final String? productName;
  final TargetMetric metric;
  final num value;
  final DateTime effectiveFrom;

  String get appliesTo => switch (scope) {
        'agent' => agentName ?? 'Agent',
        'team' => 'Team ${teamName ?? ''}',
        _ => 'Every agent',
      };
}

final targetsRepositoryProvider = Provider<TargetsRepository>((ref) => TargetsRepository(Supabase.instance.client));

final targetsProvider = FutureProvider.autoDispose<List<DailyTarget>>(
  (ref) => ref.watch(targetsRepositoryProvider).list(),
);

class TargetsRepository {
  TargetsRepository(this._client);

  final SupabaseClient _client;

  Future<List<DailyTarget>> list() async {
    final rows = await _client.rpc('list_targets') as List;
    return [for (final r in rows) DailyTarget.fromJson(Map<String, dynamic>.from(r as Map))];
  }

  /// Replaces the current target for the same agent/product/metric from today.
  Future<void> set({
    required TargetScope scope,
    required TargetMetric metric,
    required num value,
    String? agentId,
    String? productId,
  }) =>
      _client.rpc('set_daily_target', params: {
        'p_scope': scope.name,
        'p_metric': metric.name,
        'p_value': value,
        'p_agent_id': agentId,
        'p_product_id': productId,
      });
}
