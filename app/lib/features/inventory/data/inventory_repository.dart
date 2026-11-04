import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class InventoryRow {
  const InventoryRow({
    required this.productId,
    required this.name,
    required this.active,
    required this.inStore,
    required this.withAgents,
    required this.total,
  });

  factory InventoryRow.fromJson(Map<String, dynamic> j) => InventoryRow(
        productId: j['product_id'] as String,
        name: j['name'] as String,
        active: j['active'] as bool,
        inStore: j['in_store'] as int,
        withAgents: j['with_agents'] as int,
        total: j['total'] as int,
      );

  final String productId;
  final String name;
  final bool active;
  final int inStore;
  final int withAgents;
  final int total;
}

class AgentStockRow {
  const AgentStockRow(this.agentId, this.agentName, this.productId, this.productName, this.quantity);

  factory AgentStockRow.fromJson(Map<String, dynamic> j) => AgentStockRow(
        j['agent_id'] as String,
        j['agent_name'] as String,
        j['product_id'] as String,
        j['product_name'] as String,
        j['quantity'] as int,
      );

  final String agentId;
  final String agentName;
  final String productId;
  final String productName;
  final int quantity;
}

class Movement {
  const Movement({
    required this.createdAt,
    required this.type,
    required this.productName,
    required this.quantity,
    required this.fromName,
    required this.toName,
    this.reason,
    this.performedBy,
  });

  factory Movement.fromJson(Map<String, dynamic> j) => Movement(
        createdAt: DateTime.parse(j['created_at'] as String),
        type: j['movement_type'] as String,
        productName: j['product_name'] as String,
        quantity: j['quantity'] as int,
        fromName: j['from_name'] as String,
        toName: j['to_name'] as String,
        reason: j['reason'] as String?,
        performedBy: j['performed_by_name'] as String?,
      );

  final DateTime createdAt;
  final String type;
  final String productName;
  final int quantity;
  final String fromName;
  final String toName;
  final String? reason;
  final String? performedBy;
}

class Discrepancy {
  const Discrepancy({
    required this.id,
    required this.businessDate,
    required this.agentName,
    required this.productName,
    required this.expected,
    required this.reported,
    required this.difference,
  });

  factory Discrepancy.fromJson(Map<String, dynamic> j) => Discrepancy(
        id: j['id'] as String,
        businessDate: DateTime.parse(j['business_date'] as String),
        agentName: j['agent_name'] as String,
        productName: j['product_name'] as String,
        expected: j['expected_qty'] as int,
        reported: j['reported_qty'] as int,
        difference: j['difference'] as int,
      );

  final String id;
  final DateTime businessDate;
  final String agentName;
  final String productName;
  final int expected;
  final int reported;
  final int difference;
}

enum TransferKind { receipt, issue, ret }

extension on TransferKind {
  String get wire => this == TransferKind.ret ? 'return' : name;
}

class StockLine {
  const StockLine(this.productId, this.quantity);
  final String productId;
  final int quantity;

  Map<String, dynamic> toJson() => {'product_id': productId, 'quantity': quantity};
}

final inventoryRepositoryProvider = Provider<InventoryRepository>(
  (ref) => InventoryRepository(Supabase.instance.client),
);

final inventorySummaryProvider = FutureProvider.autoDispose<List<InventoryRow>>(
  (ref) => ref.watch(inventoryRepositoryProvider).summary(),
);
final stockByAgentProvider = FutureProvider.autoDispose<List<AgentStockRow>>(
  (ref) => ref.watch(inventoryRepositoryProvider).byAgent(),
);
final movementsProvider = FutureProvider.autoDispose<List<Movement>>(
  (ref) => ref.watch(inventoryRepositoryProvider).movements(),
);
final openDiscrepanciesProvider = FutureProvider.autoDispose<List<Discrepancy>>(
  (ref) => ref.watch(inventoryRepositoryProvider).openDiscrepancies(),
);

/// Refreshes every inventory view after a stock change.
void invalidateInventory(WidgetRef ref) {
  ref
    ..invalidate(inventorySummaryProvider)
    ..invalidate(stockByAgentProvider)
    ..invalidate(movementsProvider)
    ..invalidate(openDiscrepanciesProvider);
}

class InventoryRepository {
  InventoryRepository(this._client);

  final SupabaseClient _client;

  Future<List<Map<String, dynamic>>> _rows(String fn, [Map<String, dynamic>? params]) async {
    final data = await _client.rpc(fn, params: params) as List<dynamic>;
    return [for (final r in data) Map<String, dynamic>.from(r as Map)];
  }

  Future<List<InventoryRow>> summary() async => (await _rows('inventory_summary')).map(InventoryRow.fromJson).toList();
  Future<List<AgentStockRow>> byAgent() async => (await _rows('stock_by_agent')).map(AgentStockRow.fromJson).toList();
  Future<List<Movement>> movements() async => (await _rows('list_movements')).map(Movement.fromJson).toList();
  Future<List<Discrepancy>> openDiscrepancies() async =>
      (await _rows('list_discrepancies', {'p_status': 'open'})).map(Discrepancy.fromJson).toList();

  /// [opId] makes a retried submission safe: the server applies it once.
  Future<void> transfer({
    required String opId,
    required TransferKind kind,
    required List<StockLine> lines,
    String? agentId,
    String? note,
  }) =>
      _client.rpc('record_stock_transfer', params: {
        'p_client_op_id': opId,
        'p_kind': kind.wire,
        'p_lines': [for (final l in lines) l.toJson()],
        'p_agent_id': agentId,
        'p_note': note,
      });

  Future<void> writeOff({
    required String opId,
    required String type,
    required String productId,
    required int quantity,
    required String reason,
    String? agentId,
  }) =>
      _client.rpc('record_write_off', params: {
        'p_client_op_id': opId,
        'p_type': type,
        'p_product_id': productId,
        'p_quantity': quantity,
        'p_reason': reason,
        'p_agent_id': agentId,
      });

  Future<void> adjust({
    required String opId,
    required String productId,
    required int delta,
    required String reason,
    String? agentId,
  }) =>
      _client.rpc('adjust_stock', params: {
        'p_client_op_id': opId,
        'p_product_id': productId,
        'p_delta': delta,
        'p_reason': reason,
        'p_agent_id': agentId,
      });

  Future<void> resolveDiscrepancy(String id, String action, {String? note}) =>
      _client.rpc('resolve_discrepancy', params: {'p_id': id, 'p_action': action, 'p_note': note});
}

/// Short label for a movement type, as shown in the ledger.
String movementLabel(String type) => switch (type) {
      'receipt' => 'Received',
      'issue' => 'Issued',
      'return' => 'Returned',
      'sale' => 'Sold',
      'sale_void' => 'Sale voided',
      'damage' => 'Damaged',
      'loss' => 'Lost',
      'adjustment' => 'Adjusted',
      _ => type,
    };
