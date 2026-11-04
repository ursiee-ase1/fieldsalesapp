import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/design/components.dart';
import 'core/design/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!Env.isConfigured) {
    runApp(const _MissingConfigApp());
    return;
  }

  await Supabase.initialize(url: Env.supabaseUrl, publishableKey: Env.supabasePublishableKey);
  runApp(const ProviderScope(child: FieldSalesApp()));
}

/// Fails visibly instead of crashing when the build has no backend config.
class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: StateView.empty(
          icon: Icons.settings_suggest_outlined,
          title: 'App not configured',
          message: Env.supabaseUrl.isEmpty
              ? 'Run with --dart-define-from-file=env.json. See README.md.'
              : Env.urlProblem ?? 'Check app/env.json. See README.md.',
        ),
      ),
    );
  }
}
