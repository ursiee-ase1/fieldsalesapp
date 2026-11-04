import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/domain/models.dart';

class Routes {
  const Routes._();

  static const splash = '/splash';
  static const signIn = '/sign-in';
  static const signUp = '/sign-up';
  static const onboarding = '/onboarding';
  static const suspended = '/suspended';

  static const agentHome = '/agent';
  static const agentReport = '/agent/report';
  static const agentVoice = '/agent/assistant/voice';
  static const agentChat = '/agent/assistant/chat';
  static const agentCustomers = '/agent/customers';
  static const agentMe = '/agent/me';

  static const manage = '/manage';
  static const overview = '/manage/overview';
  static const agents = '/manage/agents';
  static const sales = '/manage/sales';
  static const customers = '/manage/customers';
  static const inventory = '/manage/inventory';
  static const reports = '/manage/reports';
  static const settings = '/manage/settings';
}

const _publicRoutes = {Routes.signIn, Routes.signUp};

bool _within(String location, String prefix) => location == prefix || location.startsWith('$prefix/');

/// Where the user may be, given their session. Returns null to stay put.
///
/// Keeps each role inside its own area of the app. This is navigation, not
/// security: the backend rejects anything a role isn't allowed to do.
String? resolveRedirect(AsyncValue<SessionState> session, String location) {
  // Keep showing the current screen while a refresh is in flight.
  final value = session.value;
  if (value == null) {
    return location == Routes.splash ? null : Routes.splash;
  }

  switch (value) {
    case SignedOut():
      return _publicRoutes.contains(location) ? null : Routes.signIn;
    case NeedsOnboarding():
      return location == Routes.onboarding ? null : Routes.onboarding;
    case Suspended():
      return location == Routes.suspended ? null : Routes.suspended;
    case SignedIn(:final role):
      final home = role.isManagement ? Routes.manage : Routes.agentHome;
      if (_within(location, home)) {
        return location == Routes.manage ? Routes.overview : null;
      }
      return role.isManagement ? Routes.overview : Routes.agentHome;
  }
}
