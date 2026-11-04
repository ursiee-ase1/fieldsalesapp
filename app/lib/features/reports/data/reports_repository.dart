import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format.dart';
import '../domain/report_draft.dart';

enum ReportState { none, zeroSales, withSales }

ReportState _state(String s) => switch (s) {
      'with_sales' => ReportState.withSales,
      'zero_sales' => ReportState.zeroSales,
      _ => ReportState.none,
    };

class TargetProgress {
  const TargetProgress({
    required this.metric,
    required this.target,
    required this.achieved,
    required this.progressPct,
    required this.remaining,
    this.productName,
  });

  factory TargetProgress.fromJson(Map<String, dynamic> j) => TargetProgress(
        metric: j['metric'] as String,
        productName: j['product_name'] as String?,
        target: asNum(j['target']),
        achieved: asNum(j['achieved']),
        progressPct: asNum(j['progress_pct']),
        remaining: asNum(j['remaining']),
      );

  final String metric; // units | amount
  final String? productName;
  final num target;
  final num achieved;
  final num progressPct;
  final num remaining;

  bool get isAmount => metric == 'amount';
}

class HeldStock {
  const HeldStock(this.productId, this.name, this.quantity, this.unitPrice);

  factory HeldStock.fromJson(Map<String, dynamic> j) =>
      HeldStock(j['product_id'] as String, j['name'] as String, j['quantity'] as int, asNum(j['unit_price']));

  final String productId;
  final String name;
  final int quantity;
  final num unitPrice;
}

class DueFollowUp {
  const DueFollowUp({required this.id, required this.customerName, required this.dueDate, this.phone, this.note});

  factory DueFollowUp.fromJson(Map<String, dynamic> j) => DueFollowUp(
        id: j['id'] as String,
        customerName: j['customer_name'] as String,
        phone: j['phone'] as String?,
        dueDate: DateTime.parse(j['due_date'] as String),
        note: j['note'] as String?,
      );

  final String id;
  final String customerName;
  final String? phone;
  final DateTime dueDate;
  final String? note;
}

class AgentHome {
  const AgentHome({
    required this.businessDate,
    required this.reportState,
    required this.missingCounts,
    required this.salesCount,
    required this.unitsSold,
    required this.amount,
    required this.targets,
    required this.stock,
    required this.followUps,
    this.lastReportAt,
  });

  factory AgentHome.fromJson(Map<String, dynamic> j) {
    final report = Map<String, dynamic>.from(j['report'] as Map);
    final sales = Map<String, dynamic>.from(j['sales'] as Map);
    List<Map<String, dynamic>> list(String k) => [for (final r in j[k] as List) Map<String, dynamic>.from(r as Map)];
    return AgentHome(
      businessDate: DateTime.parse(j['business_date'] as String),
      reportState: _state(report['state'] as String),
      lastReportAt: report['last_received_at'] == null ? null : DateTime.parse(report['last_received_at'] as String),
      missingCounts: report['missing_counts'] as int,
      salesCount: sales['count'] as int,
      unitsSold: sales['units'] as int,
      amount: asNum(sales['amount']),
      targets: list('targets').map(TargetProgress.fromJson).toList(),
      stock: list('stock').map(HeldStock.fromJson).toList(),
      followUps: list('follow_ups').map(DueFollowUp.fromJson).toList(),
    );
  }

  final DateTime businessDate;
  final ReportState reportState;
  final DateTime? lastReportAt;
  final int missingCounts;
  final int salesCount;
  final int unitsSold;
  final num amount;
  final List<TargetProgress> targets;
  final List<HeldStock> stock;
  final List<DueFollowUp> followUps;
}

class SubmitResult {
  const SubmitResult({
    required this.businessDate,
    required this.lateSync,
    required this.discrepancyCount,
    required this.matchReviewCount,
    required this.missingCounts,
  });

  factory SubmitResult.fromJson(Map<String, dynamic> j) => SubmitResult(
        businessDate: DateTime.parse(j['business_date'] as String),
        lateSync: j['late_sync'] as bool,
        discrepancyCount: (j['discrepancies'] as List).length,
        matchReviewCount: (j['match_reviews'] as List).length,
        missingCounts: j['missing_counts'] as int,
      );

  final DateTime businessDate;
  final bool lateSync;
  final int discrepancyCount;
  final int matchReviewCount;
  final int missingCounts;
}

class PhoneMatch {
  const PhoneMatch(this.customerId, this.firstName, this.maskedPhone);

  final String customerId;
  final String firstName;
  final String maskedPhone;
}

final reportsRepositoryProvider = Provider<ReportsRepository>(
  (ref) => ReportsRepository(Supabase.instance.client),
);

final agentHomeProvider = FutureProvider.autoDispose<AgentHome>(
  (ref) => ref.watch(reportsRepositoryProvider).agentHome(),
);

class ReportsRepository {
  ReportsRepository(this._client);

  final SupabaseClient _client;

  Future<AgentHome> agentHome() async =>
      AgentHome.fromJson(Map<String, dynamic>.from(await _client.rpc('agent_home') as Map));

  /// [opId] is fixed per draft: resubmitting after a dropped connection
  /// returns the original result instead of recording the report twice.
  Future<SubmitResult> submit(String opId, ReportDraft draft, {DateTime? capturedAt}) async {
    final result = await _client.rpc('submit_report', params: {
      'p_client_op_id': opId,
      'p_payload': draft.toPayload(),
      'p_client_captured_at': capturedAt?.toUtc().toIso8601String(),
      'p_source': 'form',
    });
    return SubmitResult.fromJson(Map<String, dynamic>.from(result as Map));
  }

  Future<List<PhoneMatch>> findByPhone(String phoneE164) async {
    final rows = await _client.rpc('find_customer_by_phone', params: {'p_phone': phoneE164}) as List;
    return [
      for (final r in rows)
        PhoneMatch(r['customer_id'] as String, r['first_name'] as String, r['masked_phone'] as String),
    ];
  }
}
