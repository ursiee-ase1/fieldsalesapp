/// Ghana-first phone normalisation for form feedback.
///
/// The database function `app.normalize_phone` is the authority; this copy
/// only gives instant feedback in forms.
String? normalizeGhanaPhone(String raw) {
  final v = raw.replaceAll(RegExp(r'[\s\-().]'), '');
  if (RegExp(r'^0[235]\d{8}$').hasMatch(v)) return '+233${v.substring(1)}';
  if (RegExp(r'^233[235]\d{8}$').hasMatch(v)) return '+$v';
  if (RegExp(r'^\+233[235]\d{8}$').hasMatch(v)) return v;
  return null;
}

/// Agents sign in with their phone number through the Email provider, so no
/// SMS provider is needed. Must match `phoneLoginEmail` in the invite-member
/// function and `app.is_phone_login` in the database.
const phoneLoginDomain = 'phone.fieldsales.invalid';

String phoneLoginEmail(String e164) => '${e164.replaceFirst('+', '')}@$phoneLoginDomain';
