import 'package:flutter/material.dart';

import '../../targets/presentation/targets_tab.dart';
import 'members_screen.dart';

/// Management "Agents" section: the team and their daily targets.
class AgentsScreen extends StatelessWidget {
  const AgentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: Icon(Icons.groups_outlined), text: 'Team members'),
              Tab(icon: Icon(Icons.flag_outlined), text: 'Daily targets'),
            ],
          ),
          Expanded(child: TabBarView(children: [MembersScreen(), TargetsTab()])),
        ],
      ),
    );
  }
}
