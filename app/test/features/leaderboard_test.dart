import 'package:field_sales/features/dashboard/data/dashboard_repository.dart';
import 'package:field_sales/features/dashboard/domain/leaderboard.dart';
import 'package:flutter_test/flutter_test.dart';

AgentActivity a(String name, {required int days, required num amount, num units = 0}) => AgentActivity(
      agentId: name,
      name: name,
      salesCount: 0,
      units: units,
      amount: amount,
      daysReported: days,
      zeroSaleDays: 0,
    );

void main() {
  test('ranks by sales per day worked, not total sales', () {
    final board = buildLeaderboard([
      a('Kofi', days: 7, amount: 1400), // 200 a day
      a('Ama', days: 4, amount: 1000), // 250 a day: fewer days, better average
    ], 7);
    expect(board.ranked.map((r) => r.agent.name), ['Ama', 'Kofi']);
    expect(board.best!.perDay, 250);
    expect(board.ranked.first.rank, 1);
  });

  test('agents who worked fewer than half the days are not ranked', () {
    final board = buildLeaderboard([
      a('Kofi', days: 6, amount: 1200),
      a('Yaw', days: 1, amount: 900), // one big day: not enough to compare fairly
      a('Esi', days: 0, amount: 0),
    ], 7);
    expect(board.minDays, 4);
    expect(board.ranked.map((r) => r.agent.name), ['Kofi']);
    expect(board.notRanked.map((r) => r.name), ['Yaw', 'Esi']);
  });

  test('zero-sales days count as days worked and lower the average', () {
    final board = buildLeaderboard([
      a('Kofi', days: 6, amount: 600), // 100 a day
      a('Ama', days: 4, amount: 600), // 150 a day
    ], 7);
    expect(board.ranked.first.agent.name, 'Ama');
    expect(board.ranked.last.perDay, 100);
  });

  test('equal averages share a rank; the steadier agent is listed first', () {
    final board = buildLeaderboard([
      a('Ama', days: 4, amount: 800),
      a('Kofi', days: 5, amount: 1000),
      a('Esi', days: 5, amount: 500),
    ], 7);
    expect(board.ranked.map((r) => '${r.rank} ${r.agent.name}'), ['1 Kofi', '1 Ama', '3 Esi']);
  });

  test('a single-day report still ranks whoever worked that day', () {
    final board = buildLeaderboard([a('Kofi', days: 1, amount: 50, units: 1)], 1);
    expect(board.minDays, 1);
    expect(board.best!.unitsPerDay, 1);
  });

  test('no best performer when nobody has sales', () {
    expect(buildLeaderboard([a('Kofi', days: 7, amount: 0)], 7).best, isNull);
  });
}
