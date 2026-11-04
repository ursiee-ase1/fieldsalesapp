import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format.dart';

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.unitPrice,
    required this.active,
    this.sku,
    this.aliases = const [],
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        id: json['id'] as String,
        name: json['name'] as String,
        unitPrice: asNum(json['unit_price']),
        active: json['active'] as bool,
        sku: json['sku'] as String?,
        aliases: [for (final a in (json['aliases'] as List? ?? const [])) a as String],
      );

  final String id;
  final String name;
  final num unitPrice;
  final bool active;
  final String? sku;
  final List<String> aliases;
}

final productsRepositoryProvider = Provider<ProductsRepository>(
  (ref) => ProductsRepository(Supabase.instance.client),
);

/// All products of the company (RLS-scoped), including inactive ones.
final productsProvider = FutureProvider.autoDispose<List<Product>>(
  (ref) => ref.watch(productsRepositoryProvider).list(),
);

class ProductsRepository {
  ProductsRepository(this._client);

  final SupabaseClient _client;

  Future<List<Product>> list() async {
    final rows = await _client.from('products').select().order('active', ascending: false).order('name');
    return rows.map(Product.fromJson).toList();
  }

  Future<void> save({
    String? id,
    required String name,
    required num unitPrice,
    String? sku,
    List<String> aliases = const [],
    bool active = true,
  }) =>
      _client.rpc('save_product', params: {
        'p_id': id,
        'p_name': name,
        'p_unit_price': unitPrice,
        'p_sku': sku,
        'p_aliases': aliases,
        'p_active': active,
      });
}
