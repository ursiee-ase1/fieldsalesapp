import 'package:field_sales/features/auth/domain/models.dart';
import 'package:field_sales/features/auth/domain/permissions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('agents can only report, never manage', () {
    for (final c in Capability.values) {
      expect(can(MemberRole.agent, c), c == Capability.submitOwnReports, reason: c.name);
    }
    expect(invitableRoles(MemberRole.agent), isEmpty);
  });

  test('managers invite agents only and cannot change company settings or roles', () {
    expect(invitableRoles(MemberRole.manager), [MemberRole.agent]);
    expect(can(MemberRole.manager, Capability.manageCompanySettings), isFalse);
    expect(can(MemberRole.manager, Capability.changeRoles), isFalse);
    expect(can(MemberRole.manager, Capability.manageStock), isTrue);
  });

  test('admins can invite every role and manage settings', () {
    expect(invitableRoles(MemberRole.admin), [MemberRole.admin, MemberRole.manager, MemberRole.agent]);
    expect(can(MemberRole.admin, Capability.manageCompanySettings), isTrue);
  });
}
