import 'dart:math' as math;

import '../data/dashboard_repository.dart';

class RankedAgent {
  const RankedAgent({required this.rank, required this.agent, required this.perDay, required this.unitsPerDay});

  final int rank;
  final AgentActivity agent;

  /// Sales amount per day worked.
  final num perDay;
  final num unitsPerDay;
}

class Leaderboard {
  const Leaderboard({required this.ranked, required this.notRanked, required this.minDays, required this.periodDays});

  final List<RankedAgent> ranked;

  /// Worked fewer than [minDays] in the period: too little to compare fairly.
  final List<AgentActivity> notRanked;
  final int minDays;
  final int periodDays;

  RankedAgent? get best => ranked.isNotEmpty && ranked.first.perDay > 0 ? ranked.first : null;
}

/// Ranks agents by average sales per day worked, so an agent who worked
/// fewer days isn't outranked just by someone who worked more.
///
/// A day worked is a day the agent sent a report, including a report of zero
/// sales. To be ranked, an agent must have worked at least half the days in
/// the period, so one lucky day can't top the table.
Leaderboard buildLeaderboard(List<AgentActivity> agents, int periodDays) {
  final minDays = math.max(1, (periodDays / 2).ceil());
  final eligible = agents.where((a) => a.daysReported >= minDays).toList();
  final notRanked = agents.where((a) => a.daysReported < minDays).toList()
    ..sort((a, b) => b.daysReported.compareTo(a.daysReported));

  num perDay(AgentActivity a) => a.amount / a.daysReported;
  eligible.sort((a, b) {
    final byAverage = perDay(b).compareTo(perDay(a));
    if (byAverage != 0) return byAverage;
    final byDays = b.daysReported.compareTo(a.daysReported); // steadier first
    return byDays != 0 ? byDays : a.name.compareTo(b.name);
  });

  final ranked = <RankedAgent>[];
  for (var i = 0; i < eligible.length; i++) {
    final a = eligible[i];
    // Equal averages share a rank.
    final rank = i > 0 && perDay(a) == perDay(eligible[i - 1]) ? ranked[i - 1].rank : i + 1;
    ranked.add(RankedAgent(rank: rank, agent: a, perDay: perDay(a), unitsPerDay: a.units / a.daysReported));
  }
  return Leaderboard(ranked: ranked, notRanked: notRanked, minDays: minDays, periodDays: periodDays);
}
