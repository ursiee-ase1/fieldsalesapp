import 'models.dart';

/// What the UI may offer to each role.
///
/// This decides which buttons appear. The database enforces the same rules
/// in RLS policies and RPC functions, which are the real security.
enum Capability {
  manageCompanySettings,
  inviteManagers,
  inviteAgents,
  suspendAgents,
  changeRoles,
  manageProducts,
  manageStock,
  viewCompanyReports,
  viewAuditLog,
  submitOwnReports,
}

const _grants = <MemberRole, Set<Capability>>{
  MemberRole.admin: {
    Capability.manageCompanySettings,
    Capability.inviteManagers,
    Capability.inviteAgents,
    Capability.suspendAgents,
    Capability.changeRoles,
    Capability.manageProducts,
    Capability.manageStock,
    Capability.viewCompanyReports,
    Capability.viewAuditLog,
  },
  MemberRole.manager: {
    Capability.inviteAgents,
    Capability.suspendAgents,
    Capability.manageProducts,
    Capability.manageStock,
    Capability.viewCompanyReports,
    Capability.viewAuditLog,
  },
  MemberRole.agent: {
    Capability.submitOwnReports,
  },
};

bool can(MemberRole role, Capability capability) => _grants[role]!.contains(capability);

/// Roles this role may invite.
List<MemberRole> invitableRoles(MemberRole role) => [
      if (can(role, Capability.inviteManagers)) ...[MemberRole.admin, MemberRole.manager],
      if (can(role, Capability.inviteAgents)) MemberRole.agent,
    ];
