import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/agent/presentation/agent_home_screen.dart';
import '../../features/assistant/presentation/assistant_screen.dart';
import '../../features/auth/application/session_controller.dart';
import '../../features/auth/domain/models.dart';
import '../../features/auth/presentation/sign_in_screen.dart';
import '../../features/auth/presentation/sign_up_screen.dart';
import '../../features/auth/presentation/status_screens.dart';
import '../../features/customers/presentation/customers_screen.dart';
import '../../features/dashboard/presentation/overview_screen.dart';
import '../../features/dashboard/presentation/reports_screen.dart';
import '../../features/inventory/presentation/inventory_screen.dart';
import '../../features/members/presentation/agents_screen.dart';
import '../../features/onboarding/presentation/create_company_screen.dart';
import '../../features/reports/presentation/report_form_screen.dart';
import '../../features/sales/presentation/sales_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../design/adaptive_nav.dart';
import 'redirect.dart';

class _Destination {
  const _Destination(this.path, this.item, this.screen);

  final String path;
  final NavItem item;
  final Widget screen;
}

final _agentDestinations = [
  const _Destination(Routes.agentHome,
      NavItem(label: 'Home', icon: Icons.home_outlined, selectedIcon: Icons.home), AgentHomeScreen()),
  const _Destination(Routes.agentCustomers,
      NavItem(label: 'Customers', icon: Icons.people_outline, selectedIcon: Icons.people), CustomersScreen()),
  const _Destination(Routes.agentMe,
      NavItem(label: 'Me', icon: Icons.person_outline, selectedIcon: Icons.person), SettingsScreen()),
];

final _managerDestinations = [
  // Order matters on phones: the first four are in the bottom bar, the rest under "More".
  const _Destination(Routes.overview,
      NavItem(label: 'Overview', icon: Icons.dashboard_outlined, selectedIcon: Icons.dashboard), OverviewScreen()),
  const _Destination(Routes.sales,
      NavItem(label: 'Sales', icon: Icons.point_of_sale_outlined, selectedIcon: Icons.point_of_sale), SalesScreen()),
  const _Destination(Routes.inventory,
      NavItem(label: 'Inventory', icon: Icons.inventory_2_outlined, selectedIcon: Icons.inventory_2),
      InventoryScreen()),
  const _Destination(Routes.customers,
      NavItem(label: 'Customers', icon: Icons.people_outline, selectedIcon: Icons.people), CustomersScreen()),
  const _Destination(Routes.agents,
      NavItem(label: 'Agents', icon: Icons.groups_outlined, selectedIcon: Icons.groups), AgentsScreen()),
  const _Destination(Routes.reports,
      NavItem(label: 'Reports', icon: Icons.insert_chart_outlined, selectedIcon: Icons.insert_chart), ReportsScreen()),
  const _Destination(Routes.settings,
      NavItem(label: 'Settings', icon: Icons.settings_outlined, selectedIcon: Icons.settings), SettingsScreen()),
];

StatefulShellRoute _shell(List<_Destination> destinations) {
  return StatefulShellRoute.indexedStack(
    builder: (context, state, shell) => _ShellFrame(shell: shell, destinations: destinations),
    branches: [
      for (final d in destinations)
        StatefulShellBranch(routes: [GoRoute(path: d.path, builder: (_, _) => d.screen)]),
    ],
  );
}

class _ShellFrame extends ConsumerWidget {
  const _ShellFrame({required this.shell, required this.destinations});

  final StatefulNavigationShell shell;
  final List<_Destination> destinations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    final company = session is SignedIn ? session.membership.companyName : null;
    return AdaptiveNavScaffold(
      items: [for (final d in destinations) d.item],
      selectedIndex: shell.currentIndex,
      onSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      header: company == null
          ? null
          : Text(company, style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
      body: shell,
    );
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  // Re-run redirects whenever the session changes.
  final refresh = ValueNotifier(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (_, state) => resolveRedirect(ref.read(sessionProvider), state.matchedLocation),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.signIn, builder: (_, _) => const SignInScreen()),
      GoRoute(path: Routes.signUp, builder: (_, _) => const SignUpScreen()),
      GoRoute(path: Routes.onboarding, builder: (_, _) => const CreateCompanyScreen()),
      GoRoute(path: Routes.suspended, builder: (_, _) => const SuspendedScreen()),
      GoRoute(path: Routes.manage, redirect: (_, _) => Routes.overview),
      GoRoute(path: Routes.agentReport, builder: (_, _) => const ReportFormScreen()),
      GoRoute(path: Routes.agentVoice, builder: (_, _) => const AssistantScreen(voice: true)),
      GoRoute(path: Routes.agentChat, builder: (_, _) => const AssistantScreen(voice: false)),
      _shell(_agentDestinations),
      _shell(_managerDestinations),
    ],
  );
});
