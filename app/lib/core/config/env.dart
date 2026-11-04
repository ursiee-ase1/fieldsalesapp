/// Build-time configuration, supplied with
/// `--dart-define-from-file=env.json` (see README).
///
/// Only public values belong here. The Supabase publishable key is designed to be
/// shipped to clients; every provider secret lives in Edge Function secrets.
class Env {
  const Env._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty && urlProblem == null;

  /// Catches the common mix-up of pasting the dashboard URL instead of the
  /// project API URL (`https://<ref>.supabase.co`).
  static String? get urlProblem {
    final uri = Uri.tryParse(supabaseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return 'SUPABASE_URL is not a valid URL.';
    if (uri.host == 'supabase.com' || uri.pathSegments.any((s) => s.isNotEmpty)) {
      return 'SUPABASE_URL must be the project API URL, like https://<project-ref>.supabase.co '
          '(not the dashboard address).';
    }
    return null;
  }
}
