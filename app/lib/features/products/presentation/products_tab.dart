import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../data/products_repository.dart';

class ProductsTab extends ConsumerWidget {
  const ProductsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(productsProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-product',
        onPressed: () => showProductForm(context),
        icon: const Icon(Icons.add),
        label: const Text('Add product'),
      ),
      body: products.when(
        loading: () => const StateView.loading(),
        error: (e, _) => StateView.error(message: describeError(e), onRetry: () => ref.invalidate(productsProvider)),
        data: (list) => list.isEmpty
            ? const StateView.empty(
                icon: Icons.category_outlined,
                title: 'No products yet',
                message: 'Add the products your agents sell, with their prices.',
              )
            : PageBody(
                maxWidth: Breakpoints.expanded,
                children: [
                  for (final p in list)
                    Card(
                      child: ListTile(
                        leading: Icon(p.active ? Icons.category_outlined : Icons.block, semanticLabel: p.active ? null : 'Inactive'),
                        title: Text(p.name),
                        subtitle: Text([
                          formatMoney(p.unitPrice),
                          if (p.sku != null) 'SKU ${p.sku}',
                          if (!p.active) 'Inactive',
                        ].join(' · ')),
                        trailing: TextButton.icon(
                          onPressed: () => showProductForm(context, product: p),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit'),
                        ),
                      ),
                    ),
                  const SizedBox(height: 72),
                ],
              ),
      ),
    );
  }
}

Future<void> showProductForm(BuildContext context, {Product? product}) => showDialog<void>(
      context: context,
      builder: (_) => _ProductForm(product: product),
    );

class _ProductForm extends ConsumerStatefulWidget {
  const _ProductForm({this.product});

  final Product? product;

  @override
  ConsumerState<_ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends ConsumerState<_ProductForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.product?.name);
  late final _price = TextEditingController(text: widget.product?.unitPrice.toString());
  late final _sku = TextEditingController(text: widget.product?.sku);
  late final _aliases = TextEditingController(text: widget.product?.aliases.join(', '));
  late bool _active = widget.product?.active ?? true;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _sku.dispose();
    _aliases.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(productsRepositoryProvider).save(
            id: widget.product?.id,
            name: _name.text.trim(),
            unitPrice: num.parse(_price.text.trim()),
            sku: _sku.text.trim().isEmpty ? null : _sku.text.trim(),
            aliases: [for (final a in _aliases.text.split(',')) if (a.trim().isNotEmpty) a.trim()],
            active: _active,
          );
      ref.invalidate(productsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.product == null ? 'Add product' : 'Edit product'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _price,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Unit price (GH₵)'),
                  validator: (v) {
                    final n = num.tryParse((v ?? '').trim());
                    return n == null || n < 0 ? 'Enter a price of 0 or more' : null;
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(controller: _sku, decoration: const InputDecoration(labelText: 'SKU (optional)')),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _aliases,
                  decoration: const InputDecoration(
                    labelText: 'Other names (optional)',
                    helperText: 'Comma-separated, e.g. names agents use in Twi',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  subtitle: const Text('Inactive products cannot be sold or issued'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
                if (_error != null) InlineMessage.error(_error!),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        BusyButton(label: 'Save', busy: _busy, onPressed: _save),
      ],
    );
  }
}
