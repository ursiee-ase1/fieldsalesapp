import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format.dart';
import '../../reports/data/reports_repository.dart';

Map<String, dynamic> _map(Object? v) => Map<String, dynamic>.from(v as Map);
List<Map<String, dynamic>> _list(Object? v) => [for (final r in (v as List? ?? const [])) _map(r)];
DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

class Totals {
  const Totals(this.salesCount, this.units, this.amount);

  factory Totals.fromJson(Map<String, dynamic> j) =>
      Totals(asNum(j['sales_count']).toInt(), asNum(j['units']).toInt(), asNum(j['amount']));

  final int salesCount;
  final int units;
  final num amount;
}

class DayPoint {
  const DayPoint(this.date, this.value, {this.units = 0});

  final DateTime date;
  final num value;
  final num units;
}

class AgentToday {
  const AgentToday({
    required this.agentId,
    required this.name,
    required this.state,
    required this.salesCount,
    required this.units,
    required this.amount,
    required this.missingCounts,
    required this.targets,
    this.lastReportAt,
    this.lastReportAny,
  });

  factory AgentToday.fromJson(Map<String, dynamic> j) => AgentToday(
        agentId: j['agent_id'] as String,
        name: j['name'] as String,
        state: switch (j['state']) {
          'with_sales' => ReportState.withSales,
          'zero_sales' => ReportState.zeroSales,
          _ => ReportState.none,
        },
        lastReportAt: _date(j['last_report_at']),
        lastReportAny: _date(j['last_report_any']),
        salesCount: asNum(j['sales_count']).toInt(),
        units: asNum(j['units']).toInt(),
        amount: asNum(j['amount']),
        missingCounts: asNum(j['missing_counts']).toInt(),
        targets: _list(j['targets']).map(TargetProgress.fromJson).toList(),
      );

  final String agentId;
  final String name;
  final ReportState state;
  final DateTime? lastReportAt;
  final DateTime? lastReportAny;
  final int salesCount;
  final int units;
  final num amount;
  final int missingCounts;
  final List<TargetProgress> targets;

  /// The all-products target, if any (the one shown on the overview).
  TargetProgress? get mainTarget => targets.where((t) => t.productName == null).firstOrNull;
}

class Overview {
  const Overview({
    required this.date,
    required this.today,
    required this.week,
    required this.weekByDay,
    required this.agents,
    required this.newCustomersToday,
    required this.newCustomersWeek,
    required this.followUpsDue,
    required this.openDiscrepancies,
    required this.duplicateReviews,
    required this.flaggedSalesToday,
    required this.stockInStore,
    required this.stockWithAgents,
  });

  factory Overview.fromJson(Map<String, dynamic> j) {
    final customers = _map(j['customers']);
    final attention = _map(j['attention']);
    final stock = _map(j['stock']);
    return Overview(
      date: DateTime.parse(j['date'] as String),
      today: Totals.fromJson(_map(j['today'])),
      week: Totals.fromJson(_map(j['week'])),
      weekByDay: [
        for (final d in _list(j['week_by_day']))
          DayPoint(DateTime.parse(d['date'] as String), asNum(d['amount']), units: asNum(d['units'])),
      ],
      agents: _list(j['agents']).map(AgentToday.fromJson).toList(),
      newCustomersToday: asNum(customers['new_today']).toInt(),
      newCustomersWeek: asNum(customers['new_week']).toInt(),
      followUpsDue: asNum(customers['follow_ups_due']).toInt(),
      openDiscrepancies: asNum(attention['open_discrepancies']).toInt(),
      duplicateReviews: asNum(attention['duplicate_reviews']).toInt(),
      flaggedSalesToday: asNum(attention['flagged_sales_today']).toInt(),
      stockInStore: asNum(stock['in_store']).toInt(),
      stockWithAgents: asNum(stock['with_agents']).toInt(),
    );
  }

  final DateTime date;
  final Totals today;
  final Totals week;
  final List<DayPoint> weekByDay;
  final List<AgentToday> agents;
  final int newCustomersToday;
  final int newCustomersWeek;
  final int followUpsDue;
  final int openDiscrepancies;
  final int duplicateReviews;
  final int flaggedSalesToday;
  final int stockInStore;
  final int stockWithAgents;

  int get reportedCount => agents.where((a) => a.state != ReportState.none).length;
}

class ProductSales {
  const ProductSales(this.name, this.units, this.amount);
  final String name;
  final num units;
  final num amount;
}

class AgentActivity {
  const AgentActivity({
    required this.agentId,
    required this.name,
    required this.salesCount,
    required this.units,
    required this.amount,
    required this.daysReported,
    required this.zeroSaleDays,
    this.lastReportAt,
  });

  final String agentId;
  final String name;
  final int salesCount;
  final num units;
  final num amount;
  final int daysReported;
  final int zeroSaleDays;
  final DateTime? lastReportAt;
}

class SalesReport {
  const SalesReport({
    required this.days,
    required this.totals,
    required this.byDay,
    required this.byProduct,
    required this.byAgent,
    required this.customersByDay,
  });

  factory SalesReport.fromJson(Map<String, dynamic> j) => SalesReport(
        days: asNum(j['days']).toInt(),
        totals: Totals.fromJson(_map(j['totals'])),
        byDay: [
          for (final d in _list(j['by_day']))
            DayPoint(DateTime.parse(d['date'] as String), asNum(d['amount']), units: asNum(d['units'])),
        ],
        byProduct: [
          for (final p in _list(j['by_product'])) ProductSales(p['name'] as String, asNum(p['units']), asNum(p['amount'])),
        ],
        byAgent: [
          for (final a in _list(j['by_agent']))
            AgentActivity(
              agentId: a['agent_id'] as String,
              name: a['name'] as String,
              salesCount: asNum(a['sales_count']).toInt(),
              units: asNum(a['units']),
              amount: asNum(a['amount']),
              daysReported: asNum(a['days_reported']).toInt(),
              zeroSaleDays: asNum(a['zero_sale_days']).toInt(),
              lastReportAt: _date(a['last_report_at']),
            ),
        ],
        customersByDay: [
          for (final d in _list(j['customers_by_day'])) DayPoint(DateTime.parse(d['date'] as String), asNum(d['count'])),
        ],
      );

  final int days;
  final Totals totals;
  final List<DayPoint> byDay;
  final List<ProductSales> byProduct;
  final List<AgentActivity> byAgent;
  final List<DayPoint> customersByDay;
}

class ConversationSummary {
  const ConversationSummary({
    required this.sessionId,
    required this.businessDate,
    required this.agentName,
    required this.channel,
    required this.language,
    required this.status,
    required this.turns,
    required this.lastTurnAt,
  });

  factory ConversationSummary.fromJson(Map<String, dynamic> j) => ConversationSummary(
        sessionId: j['session_id'] as String,
        businessDate: DateTime.parse(j['business_date'] as String),
        agentName: j['agent_name'] as String,
        channel: j['channel'] as String,
        language: j['language'] as String,
        status: j['status'] as String,
        turns: asNum(j['turns']).toInt(),
        lastTurnAt: DateTime.parse(j['last_turn_at'] as String),
      );

  final String sessionId;
  final DateTime businessDate;
  final String agentName;
  final String channel;
  final String language;
  final String status;
  final int turns;
  final DateTime lastTurnAt;
}

class TranscriptLine {
  const TranscriptLine({required this.fromAgent, required this.text, required this.createdAt, this.englishText, this.voice = false});

  final bool fromAgent;
  final String text;
  final String? englishText;
  final bool voice;
  final DateTime createdAt;
}

class CompanySettings {
  const CompanySettings({
    required this.twiVoiceEnabled,
    required this.khayaMonthlyCalls,
    required this.maxDiscountPct,
    required this.khayaCallsUsed,
  });

  factory CompanySettings.fromJson(Map<String, dynamic> j) => CompanySettings(
        twiVoiceEnabled: j['twi_voice_enabled'] as bool,
        khayaMonthlyCalls: asNum(j['khaya_monthly_calls']).toInt(),
        maxDiscountPct: asNum(j['max_discount_pct']),
        khayaCallsUsed: asNum(j['khaya_calls_used_this_month']).toInt(),
      );

  final bool twiVoiceEnabled;
  final int khayaMonthlyCalls;
  final num maxDiscountPct;
  final int khayaCallsUsed;
}

/// Filters for the sales report. Null lists mean "all".
class ReportFilter {
  const ReportFilter({required this.from, required this.to, this.agentId, this.productId});

  final DateTime from;
  final DateTime to;
  final String? agentId;
  final String? productId;

  ReportFilter copyWith({DateTime? from, DateTime? to, String? Function()? agentId, String? Function()? productId}) =>
      ReportFilter(
        from: from ?? this.from,
        to: to ?? this.to,
        agentId: agentId != null ? agentId() : this.agentId,
        productId: productId != null ? productId() : this.productId,
      );

  @override
  bool operator ==(Object other) =>
      other is ReportFilter && other.from == from && other.to == to && other.agentId == agentId && other.productId == productId;

  @override
  int get hashCode => Object.hash(from, to, agentId, productId);
}

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) => DashboardRepository(Supabase.instance.client));

class DashboardRepository {
  DashboardRepository(this._client);

  final SupabaseClient _client;

  Future<Overview> overview(DateTime? date) async => Overview.fromJson(
        _map(await _client.rpc('dashboard_overview', params: {'p_date': date == null ? null : isoDate(date)})),
      );

  Future<SalesReport> salesReport(ReportFilter f) async => SalesReport.fromJson(_map(await _client.rpc('sales_report', params: {
        'p_from': isoDate(f.from),
        'p_to': isoDate(f.to),
        'p_agent_ids': f.agentId == null ? null : [f.agentId],
        'p_product_ids': f.productId == null ? null : [f.productId],
      })));

  Future<List<ConversationSummary>> conversations(DateTime from, DateTime to) async {
    final rows = await _client.rpc('list_conversations', params: {'p_from': isoDate(from), 'p_to': isoDate(to)}) as List;
    return [for (final r in rows) ConversationSummary.fromJson(_map(r))];
  }

  Future<List<TranscriptLine>> transcript(String sessionId) async {
    final rows = await _client.rpc('conversation_transcript', params: {'p_session': sessionId}) as List;
    return [
      for (final r in rows.map(_map))
        TranscriptLine(
          fromAgent: r['role'] == 'agent',
          text: r['text'] as String,
          englishText: r['english_text'] as String?,
          voice: r['input_mode'] == 'voice',
          createdAt: DateTime.parse(r['created_at'] as String),
        ),
    ];
  }

  Future<CompanySettings> settings() async => CompanySettings.fromJson(_map(await _client.rpc('company_settings')));

  Future<CompanySettings> updateSettings(Map<String, Object> patch) async =>
      CompanySettings.fromJson(_map(await _client.rpc('update_company_settings', params: {'p_patch': patch})));
}

// --- Providers -------------------------------------------------------------------

final overviewDateProvider = NotifierProvider<OverviewDate, DateTime?>(OverviewDate.new);

/// Null means "today" in the company's timezone, as decided by the server.
/// A non-null value is always a past day.
class OverviewDate extends Notifier<DateTime?> {
  /// The server's business date, learned from the live view. Comparing with
  /// this (not the device clock) keeps "today" consistent with the data.
  DateTime? serverToday;

  @override
  DateTime? build() => null;

  void set(DateTime? date) {
    final today = serverToday;
    state = date != null && today != null && !date.isBefore(today) ? null : date;
  }
}

final overviewProvider = FutureProvider.autoDispose<Overview>((ref) async {
  final selected = ref.watch(overviewDateProvider);
  final overview = await ref.watch(dashboardRepositoryProvider).overview(selected);
  if (selected == null) ref.read(overviewDateProvider.notifier).serverToday = overview.date;
  return overview;
});

final reportFilterProvider = NotifierProvider<ReportFilterController, ReportFilter>(ReportFilterController.new);

class ReportFilterController extends Notifier<ReportFilter> {
  @override
  ReportFilter build() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return ReportFilter(from: today.subtract(const Duration(days: 6)), to: today);
  }

  void set(ReportFilter f) => state = f;
}

final salesReportProvider = FutureProvider.autoDispose<SalesReport>(
  (ref) => ref.watch(dashboardRepositoryProvider).salesReport(ref.watch(reportFilterProvider)),
);

final conversationsProvider = FutureProvider.autoDispose<List<ConversationSummary>>((ref) {
  final f = ref.watch(reportFilterProvider);
  return ref.watch(dashboardRepositoryProvider).conversations(f.from, f.to);
});

final companySettingsProvider = FutureProvider.autoDispose<CompanySettings>(
  (ref) => ref.watch(dashboardRepositoryProvider).settings(),
);
