import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format.dart';

class SaleRecord {
  const SaleRecord({
    required this.id,
    required this.recordedAt,
    required this.businessDate,
    required this.agentName,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    required this.total,
    required this.paymentMethod,
    required this.priceOverride,
    required this.priceFlagged,
    required this.stockFlagged,
    this.customerName,
    this.voidedAt,
    this.voidReason,
  });

  factory SaleRecord.fromJson(Map<String, dynamic> j) => SaleRecord(
        id: j['id'] as String,
        recordedAt: DateTime.parse(j['recorded_at'] as String),
        businessDate: DateTime.parse(j['business_date'] as String),
        agentName: j['agent_name'] as String,
        productName: j['product_name'] as String,
        quantity: j['quantity'] as int,
        unitPrice: asNum(j['unit_price']),
        total: asNum(j['total_amount']),
        paymentMethod: j['payment_method'] as String,
        customerName: j['customer_name'] as String?,
        priceOverride: j['price_override'] as bool,
        priceFlagged: j['price_flagged'] as bool,
        stockFlagged: j['stock_flagged'] as bool,
        voidedAt: j['voided_at'] == null ? null : DateTime.parse(j['voided_at'] as String),
        voidReason: j['void_reason'] as String?,
      );

  final String id;
  final DateTime recordedAt;
  final DateTime businessDate;
  final String agentName;
  final String productName;
  final int quantity;
  final num unitPrice;
  final num total;
  final String paymentMethod;
  final String? customerName;
  final bool priceOverride;
  final bool priceFlagged;
  final bool stockFlagged;
  final DateTime? voidedAt;
  final String? voidReason;

  bool get isVoided => voidedAt != null;
}

enum SalesPeriod {
  today('Today', 0),
  week('Last 7 days', 6),
  month('Last 30 days', 29);

  const SalesPeriod(this.label, this.daysBack);
  final String label;
  final int daysBack;
}

final salesRepositoryProvider = Provider<SalesRepository>((ref) => SalesRepository(Supabase.instance.client));

final salesPeriodProvider = NotifierProvider<SalesPeriodController, SalesPeriod>(SalesPeriodController.new);

class SalesPeriodController extends Notifier<SalesPeriod> {
  @override
  SalesPeriod build() => SalesPeriod.today;

  void set(SalesPeriod value) => state = value;
}

final salesProvider = FutureProvider.autoDispose<List<SaleRecord>>((ref) {
  final period = ref.watch(salesPeriodProvider);
  final today = DateTime.now();
  return ref.watch(salesRepositoryProvider).list(today.subtract(Duration(days: period.daysBack)), today);
});

class SalesRepository {
  SalesRepository(this._client);

  final SupabaseClient _client;

  Future<List<SaleRecord>> list(DateTime from, DateTime to) async {
    final rows = await _client.rpc('list_sales', params: {'p_from': isoDate(from), 'p_to': isoDate(to)}) as List;
    return [for (final r in rows) SaleRecord.fromJson(Map<String, dynamic>.from(r as Map))];
  }

  Future<void> voidSale(String id, String reason) =>
      _client.rpc('void_sale', params: {'p_sale_id': id, 'p_reason': reason});
}
