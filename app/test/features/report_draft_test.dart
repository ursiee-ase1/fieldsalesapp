import 'package:field_sales/features/reports/domain/report_draft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 11, 4);
  DraftIssues check(ReportDraft d, {bool amending = false, Map<String, String> held = const {}}) =>
      d.check(alreadyReportedToday: amending, heldProducts: held, today: today);

  test('a first report needs sales or an explicit "no sales"', () {
    final d = ReportDraft();
    expect(check(d).canSubmit, isFalse);
    d.noSales = true;
    expect(check(d).canSubmit, isTrue);
  });

  test('an amendment may carry only stock counts', () {
    final d = ReportDraft()..stockCounts['p1'] = 4;
    expect(check(d, amending: true).canSubmit, isTrue);
  });

  test('"no sales" with sales listed is contradictory', () {
    final d = ReportDraft()
      ..noSales = true
      ..sales.add(SaleLine(productId: 'p1'));
    expect(check(d).errors, contains(contains('no sales')));
  });

  test('a phone number needs the customer\'s consent and must be valid', () {
    final c = CustomerEntry(fullName: 'Ama Mensah', phone: '024 123 4567');
    final d = ReportDraft()
      ..noSales = true
      ..customers.add(c);
    expect(check(d).errors.single, contains('agreed'));
    c.consent = true;
    expect(check(d).canSubmit, isTrue);
    c.phone = '12345';
    expect(check(d).errors.single, contains('not valid'));
  });

  test('follow-up dates must be within 90 days', () {
    final c = CustomerEntry(fullName: 'Kofi Boateng')..followUpDate = today.add(const Duration(days: 91));
    final d = ReportDraft()
      ..noSales = true
      ..customers.add(c);
    expect(check(d).canSubmit, isFalse);
    c.followUpDate = today.add(const Duration(days: 1));
    expect(check(d).canSubmit, isTrue);
  });

  test('uncounted stock is a warning, not an error', () {
    final d = ReportDraft()..noSales = true;
    final issues = check(d, held: {'p1': 'Book A', 'p2': 'Book B'});
    expect(issues.canSubmit, isTrue);
    expect(issues.warnings.single, 'Stock not counted: Book A, Book B.');
  });

  test('payload matches the submit_report contract', () {
    final newCustomer = CustomerEntry(fullName: ' Ama Mensah ', phone: '0241234567', consent: true)
      ..followUpDate = DateTime(2026, 11, 5)
      ..followUpNote = 'Bring Book B';
    final existing = CustomerEntry()
      ..existingCustomerId = 'cust-9'
      ..existingFirstName = 'Kofi';
    final sale = SaleLine(productId: 'p1', quantity: 2, payment: PaymentMethod.momo, customerRef: newCustomer.ref);
    final d = ReportDraft()
      ..sales.add(sale)
      ..customers.addAll([newCustomer, existing])
      ..stockCounts['p1'] = 3
      ..followUpOutcomes['f1'] = FollowUpOutcome.notReached
      ..prospectsCount = 5;

    final p = d.toPayload();
    expect(p.containsKey('no_sales'), isFalse);
    expect(p['sales'], [
      {'id': sale.id, 'product_id': 'p1', 'quantity': 2, 'payment_method': 'momo', 'customer_ref': newCustomer.ref},
    ]);
    expect(p['customers'], [
      {'ref': newCustomer.ref, 'full_name': 'Ama Mensah', 'phone': '+233241234567', 'consent': true},
      {'ref': existing.ref, 'customer_id': 'cust-9'},
    ]);
    expect(p['follow_ups'], [
      {'customer_ref': newCustomer.ref, 'due_date': '2026-11-05', 'note': 'Bring Book B'},
    ]);
    expect(p['follow_up_outcomes'], [
      {'follow_up_id': 'f1', 'outcome': 'not_reached'},
    ]);
    expect(p['stock_counts'], [
      {'product_id': 'p1', 'quantity': 3},
    ]);
    expect(p['prospects_count'], 5);
  });

  test('sale ids are unique and stable per line', () {
    final a = SaleLine(productId: 'p1');
    final b = SaleLine(productId: 'p1');
    expect(a.id, isNot(b.id));
    expect(a.id, a.id);
  });
}
