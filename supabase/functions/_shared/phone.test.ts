import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeGhanaPhone, phoneLoginEmail } from './phone.ts';

test('normalizes Ghana numbers like the database does', () => {
  for (const raw of ['024 123 4567', '0241234567', '233241234567', '+233 24-123-4567', '(024) 123 4567']) {
    assert.equal(normalizeGhanaPhone(raw), '+233241234567', raw);
  }
  for (const bad of ['', '12345', '0141234567', '+2332412345678', 'abc']) {
    assert.equal(normalizeGhanaPhone(bad), null, bad);
  }
});

test('maps a phone number to its login email (same as the app)', () => {
  assert.equal(phoneLoginEmail('+233241234567'), '233241234567@phone.fieldsales.invalid');
});
