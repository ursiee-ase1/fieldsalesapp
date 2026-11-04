enum MemberRole {
  admin,
  manager,
  agent;

  static MemberRole parse(String value) =>
      MemberRole.values.firstWhere((r) => r.name == value, orElse: () => throw FormatException('Unknown role: $value'));

  String get label => switch (this) {
        MemberRole.admin => 'Administrator',
        MemberRole.manager => 'Manager',
        MemberRole.agent => 'Field agent',
      };

  bool get isManagement => this != MemberRole.agent;
}

enum MemberStatus {
  active,
  suspended;

  static MemberStatus parse(String value) => value == 'suspended' ? suspended : active;
}

class Membership {
  const Membership({
    required this.id,
    required this.companyId,
    required this.companyName,
    required this.role,
    required this.status,
  });

  factory Membership.fromJson(Map<String, dynamic> json) => Membership(
        id: json['id'] as String,
        companyId: json['company_id'] as String,
        companyName: json['company_name'] as String,
        role: MemberRole.parse(json['role'] as String),
        status: MemberStatus.parse(json['status'] as String),
      );

  final String id;
  final String companyId;
  final String companyName;
  final MemberRole role;
  final MemberStatus status;
}

/// Result of `public.my_context()`.
class UserContext {
  const UserContext({required this.userId, this.fullName, this.preferredLanguage = 'en', this.membership});

  factory UserContext.fromJson(Map<String, dynamic> json) => UserContext(
        userId: json['user_id'] as String,
        fullName: json['full_name'] as String?,
        preferredLanguage: (json['preferred_language'] as String?) ?? 'en',
        membership: json['membership'] == null
            ? null
            : Membership.fromJson(Map<String, dynamic>.from(json['membership'] as Map)),
      );

  final String userId;
  final String? fullName;
  final String preferredLanguage;
  final Membership? membership;
}

sealed class SessionState {
  const SessionState();
}

class SignedOut extends SessionState {
  const SignedOut();
}

/// Signed in, but not yet part of a company: must create one.
class NeedsOnboarding extends SessionState {
  const NeedsOnboarding(this.context);
  final UserContext context;
}

class Suspended extends SessionState {
  const Suspended(this.context);
  final UserContext context;
}

class SignedIn extends SessionState {
  const SignedIn(this.context, this.membership);
  final UserContext context;
  final Membership membership;

  MemberRole get role => membership.role;
}

SessionState sessionFromContext(UserContext context) {
  final membership = context.membership;
  if (membership == null) return NeedsOnboarding(context);
  if (membership.status == MemberStatus.suspended) return Suspended(context);
  return SignedIn(context, membership);
}
