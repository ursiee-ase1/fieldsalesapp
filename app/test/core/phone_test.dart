import 'package:field_sales/core/phone.dart';
import 'package:flutter_test/flutter_test.dart';

// Same cases as supabase/tests (app.normalize_phone) so the two stay in step.
void main() {
  test('normalizes common Ghana formats', () {
    for (final raw in ['024 123 4567', '0241234567', '233241234567', '+233 24-123-4567', '(024) 123 4567']) {
      expect(normalizeGhanaPhone(raw), '+233241234567', reason: raw);
    }
    expect(normalizeGhanaPhone('0551234567'), '+233551234567');
  });

  test('rejects invalid input', () {
    for (final bad in ['', '12345', '0141234567', '+2332412345678', 'abc']) {
      expect(normalizeGhanaPhone(bad), isNull, reason: bad);
    }
  });

  test('maps a phone number to its login email (same as invite-member)', () {
    expect(phoneLoginEmail('+233241234567'), '233241234567@phone.fieldsales.invalid');
  });
}
