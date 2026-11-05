import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns backend errors into messages a field agent or manager can act on.
String describeError(Object error) {
  if (error is AuthException) {
    if (_isNetworkError(error.message)) return _offlineMessage;
    final m = error.message.toLowerCase();
    if (m.contains('invalid login credentials')) return 'Wrong sign-in details. Check them and try again.';
    if (m.contains('email not confirmed')) return 'Confirm your email first: open the link we sent you, then sign in.';
    if (m.contains('password should be')) return 'Choose a longer password (at least 8 characters).';
    return error.message;
  }
  if (error is PostgrestException) {
    final m = error.message;
    final detail = error.details is String && (error.details as String).isNotEmpty ? error.details as String : null;
    if (m.contains('validation_failed') && detail != null) return _sentence(detail);
    if (m.contains('insufficient_stock')) return 'Not enough stock. ${detail ?? ''}'.trim();
    if (m.contains('conflict')) return 'Someone else changed this record. Reload and try again.';
    if (m.contains('rate_limited')) return 'Too many lookups. Please wait a while and try again.';
    if (m.contains('duplicate_sale')) return 'This sale was already recorded.';
    if (m.contains('already_resolved') || m.contains('already_voided')) return 'This was already handled.';
    if (m.contains('email_account_required')) return 'Sign up with an email address to create a company.';
    if (m.contains('already_member')) return 'This account already belongs to a company.';
    if (m.contains('invalid_phone')) return 'That phone number is not valid.';
    if (m.contains('cannot_modify_self')) return 'You cannot change your own role or status.';
    if (error.code == '42501' || m.contains('forbidden')) return "You don't have permission to do that.";
    if (error.code == 'P0002') return 'That record no longer exists.';
    return 'The server rejected the request. Please try again.';
  }
  if (error is FunctionException) {
    final details = error.details;
    if (details is Map && details['message'] is String) {
      final problems = details['details'];
      if (problems is List && problems.isNotEmpty) return problems.join('\n');
      return details['message'] as String;
    }
    return 'The server could not complete the request (${error.status}).';
  }
  if (_isNetworkError(error.toString())) return _offlineMessage;
  return 'Something went wrong. Please try again.';
}

const _offlineMessage = "Couldn't reach the server. Check your internet connection and try again.";

bool _isNetworkError(String text) =>
    text.contains('SocketException') ||
    text.contains('ClientException') ||
    text.contains('Failed to fetch') ||
    text.contains('Failed host lookup');

String _sentence(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}.';
