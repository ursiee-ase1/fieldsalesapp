// Mirrors app.normalize_phone in the database, which remains the authority.
export function normalizeGhanaPhone(raw: string): string | null {
  const v = raw.replace(/[\s\-().]/g, '');
  if (/^0[235]\d{8}$/.test(v)) return '+233' + v.slice(1);
  if (/^233[235]\d{8}$/.test(v)) return '+' + v;
  if (/^\+233[235]\d{8}$/.test(v)) return v;
  return null;
}

// Agents sign in with their phone number through the Email provider (no SMS
// provider needed). Must match phoneLoginEmail in the app and
// app.is_phone_login in the database.
export const PHONE_LOGIN_DOMAIN = 'phone.fieldsales.invalid';

export function phoneLoginEmail(e164: string): string {
  return `${e164.replace(/^\+/, '')}@${PHONE_LOGIN_DOMAIN}`;
}
