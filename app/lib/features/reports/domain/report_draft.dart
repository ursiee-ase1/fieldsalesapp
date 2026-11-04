import '../../../core/format.dart';
import '../../../core/phone.dart';

enum PaymentMethod {
  cash('Cash'),
  momo('Mobile Money');

  const PaymentMethod(this.label);
  final String label;
}

enum FollowUpOutcome {
  contacted('Contacted', 'contacted'),
  notReached('Not reached', 'not_reached'),
  sold('Sold', 'sold'),
  notInterested('Not interested', 'not_interested');

  const FollowUpOutcome(this.label, this.wire);
  final String label;
  final String wire;
}

class SaleLine {
  SaleLine({required this.productId, this.quantity = 1, this.unitPrice, this.payment = PaymentMethod.cash, this.customerRef})
      : id = newId();

  /// Client-generated, so a retried submission can never record the sale twice.
  final String id;
  String productId;
  int quantity;

  /// Null means the catalog price.
  num? unitPrice;
  PaymentMethod payment;
  String? customerRef;
}

class CustomerEntry {
  CustomerEntry({this.fullName = '', this.phone = '', this.consent = false}) : ref = 'c-${newId()}';

  final String ref;
  String fullName;
  String phone;
  bool consent;
  String location = '';
  String notes = '';

  /// Set when the agent confirmed the phone belongs to an existing customer.
  String? existingCustomerId;
  String? existingFirstName;

  /// Existing customers the agent said this is *not*.
  final Set<String> notSameAs = {};

  DateTime? followUpDate;
  String followUpNote = '';

  bool get isExisting => existingCustomerId != null;
  String? get normalizedPhone => phone.trim().isEmpty ? null : normalizeGhanaPhone(phone);
  String get displayName => isExisting ? (existingFirstName ?? 'Existing customer') : fullName.trim();
}

class DraftIssues {
  const DraftIssues(this.errors, this.warnings);

  /// Must be fixed before submitting (the server would reject them too).
  final List<String> errors;

  /// Allowed, but worth a second look (e.g. stock not counted).
  final List<String> warnings;

  bool get canSubmit => errors.isEmpty;
}

/// A daily report being prepared by an agent. The same payload is produced
/// by the form today and by the AI assistant later.
class ReportDraft {
  bool noSales = false;
  final List<SaleLine> sales = [];
  final List<CustomerEntry> customers = [];

  /// productId -> counted quantity
  final Map<String, int> stockCounts = {};

  /// followUpId -> outcome
  final Map<String, FollowUpOutcome> followUpOutcomes = {};
  int? prospectsCount;
  String comments = '';

  bool get hasContent =>
      noSales ||
      sales.isNotEmpty ||
      customers.isNotEmpty ||
      stockCounts.isNotEmpty ||
      followUpOutcomes.isNotEmpty ||
      prospectsCount != null ||
      comments.trim().isNotEmpty;

  /// [alreadyReportedToday]: a report exists, so this submission amends it
  /// and does not need to restate sales.
  DraftIssues check({
    required bool alreadyReportedToday,
    required Map<String, String> heldProducts, // productId -> name
    required DateTime today,
  }) {
    final errors = <String>[];
    final warnings = <String>[];

    if (noSales && sales.isNotEmpty) errors.add('You marked "no sales" but also added sales.');
    if (!alreadyReportedToday && !noSales && sales.isEmpty) {
      errors.add('Add your sales, or tick "I made no sales today".');
    }
    for (final s in sales) {
      if (s.quantity <= 0) errors.add('Each sale needs a quantity of at least 1.');
      if (s.unitPrice != null && s.unitPrice! < 0) errors.add('Prices cannot be negative.');
    }
    final refs = {for (final c in customers) c.ref};
    if (sales.any((s) => s.customerRef != null && !refs.contains(s.customerRef))) {
      errors.add('A sale is linked to a customer that was removed.');
    }
    for (final c in customers.where((c) => !c.isExisting)) {
      if (c.fullName.trim().length < 2) errors.add('Each new customer needs a name.');
      if (c.phone.trim().isNotEmpty && c.normalizedPhone == null) {
        errors.add('${c.displayName.isEmpty ? 'A customer' : c.displayName}: phone number is not valid.');
      }
      if (c.normalizedPhone != null && !c.consent) {
        errors.add('${c.displayName}: confirm the customer agreed to share their phone number.');
      }
    }
    for (final c in customers.where((c) => c.followUpDate != null)) {
      final days = c.followUpDate!.difference(DateTime(today.year, today.month, today.day)).inDays;
      if (days < 0 || days > 90) errors.add('${c.displayName}: follow-up date must be within the next 90 days.');
    }
    if (prospectsCount != null && prospectsCount! < 0) errors.add('Prospects cannot be negative.');
    if (stockCounts.values.any((q) => q < 0)) errors.add('Stock counts cannot be negative.');

    final uncounted = heldProducts.entries.where((e) => !stockCounts.containsKey(e.key)).map((e) => e.value);
    if (uncounted.isNotEmpty) warnings.add('Stock not counted: ${uncounted.join(', ')}.');

    return DraftIssues(errors.toSet().toList(), warnings);
  }

  Map<String, dynamic> toPayload() => {
        if (noSales) 'no_sales': true,
        'customers': [
          for (final c in customers)
            if (c.isExisting)
              {'ref': c.ref, 'customer_id': c.existingCustomerId}
            else
              {
                'ref': c.ref,
                'full_name': c.fullName.trim(),
                if (c.normalizedPhone != null) 'phone': c.normalizedPhone,
                'consent': c.consent,
                if (c.location.trim().isNotEmpty) 'location': c.location.trim(),
                if (c.notes.trim().isNotEmpty) 'notes': c.notes.trim(),
                if (c.notSameAs.isNotEmpty) 'not_same_as': c.notSameAs.toList(),
              },
        ],
        'sales': [
          for (final s in sales)
            {
              'id': s.id,
              'product_id': s.productId,
              'quantity': s.quantity,
              if (s.unitPrice != null) 'unit_price': s.unitPrice,
              'payment_method': s.payment.name,
              if (s.customerRef != null) 'customer_ref': s.customerRef,
            },
        ],
        'stock_counts': [
          for (final e in stockCounts.entries) {'product_id': e.key, 'quantity': e.value},
        ],
        'follow_ups': [
          for (final c in customers.where((c) => c.followUpDate != null))
            {
              'customer_ref': c.ref,
              'due_date': isoDate(c.followUpDate!),
              if (c.followUpNote.trim().isNotEmpty) 'note': c.followUpNote.trim(),
            },
        ],
        'follow_up_outcomes': [
          for (final e in followUpOutcomes.entries) {'follow_up_id': e.key, 'outcome': e.value.wire},
        ],
        if (prospectsCount != null) 'prospects_count': prospectsCount,
        if (comments.trim().isNotEmpty) 'comments': comments.trim(),
      };
}
