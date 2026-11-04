import 'dart:async';

import 'package:field_sales/features/auth/data/auth_repository.dart';
import 'package:field_sales/features/auth/domain/models.dart';

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this.signedIn = false, UserContext? context})
      : context = context ?? const UserContext(userId: 'u1');

  bool signedIn;
  UserContext context;
  final calls = <String>[];
  final _changes = StreamController<void>.broadcast();

  void emitChange() => _changes.add(null);

  @override
  bool get hasSession => signedIn;

  @override
  Stream<void> get sessionChanges => _changes.stream;

  @override
  Future<UserContext> fetchContext() async => context;

  @override
  Future<void> signInWithPhone(String phoneE164, String password) async {
    calls.add('phone:$phoneE164');
    signedIn = true;
  }

  @override
  Future<void> signInWithEmail(String email, String password) async {
    calls.add('email:$email');
    signedIn = true;
  }

  @override
  Future<SignUpResult> signUpWithEmail(String email, String password) async => SignUpResult.signedIn;

  @override
  Future<void> signOut() async => signedIn = false;
}

Membership membership(MemberRole role, {MemberStatus status = MemberStatus.active}) => Membership(
      id: 'm1',
      companyId: 'c1',
      companyName: 'Alpha Books',
      role: role,
      status: status,
    );
