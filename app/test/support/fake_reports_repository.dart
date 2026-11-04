import 'package:field_sales/features/products/data/products_repository.dart';
import 'package:field_sales/features/reports/data/reports_repository.dart';
import 'package:field_sales/features/reports/domain/report_draft.dart';

class FakeReportsRepository implements ReportsRepository {
  FakeReportsRepository({required this.home, this.matches = const []});

  AgentHome home;
  List<PhoneMatch> matches;
  final submitted = <Map<String, dynamic>>[];
  final opIds = <String>[];

  @override
  Future<AgentHome> agentHome() async => home;

  @override
  Future<SubmitResult> submit(String opId, ReportDraft draft, {DateTime? capturedAt}) async {
    opIds.add(opId);
    submitted.add(draft.toPayload());
    return SubmitResult(
      businessDate: home.businessDate,
      lateSync: false,
      discrepancyCount: 0,
      matchReviewCount: 0,
      missingCounts: 0,
    );
  }

  @override
  Future<List<PhoneMatch>> findByPhone(String phoneE164) async => matches;
}

AgentHome agentHome({
  ReportState state = ReportState.none,
  List<HeldStock> stock = const [],
  int salesCount = 0,
}) =>
    AgentHome(
      businessDate: DateTime(2026, 11, 4),
      reportState: state,
      lastReportAt: state == ReportState.none ? null : DateTime(2026, 11, 4, 15, 30),
      missingCounts: 0,
      salesCount: salesCount,
      unitsSold: salesCount,
      amount: salesCount * 50,
      targets: const [],
      stock: stock,
      followUps: const [],
    );

const bookA = Product(id: 'p-a', name: 'Book A', unitPrice: 50, active: true);
