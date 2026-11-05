import 'package:flutter/material.dart';

import 'tokens.dart';

class NavItem {
  const NavItem({required this.label, required this.icon, required this.selectedIcon});

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Navigation that adapts to width:
///  * compact: bottom bar (≤5 items), or the first four plus "More"
///  * medium: navigation rail
///  * expanded: extended navigation rail
class AdaptiveNavScaffold extends StatelessWidget {
  const AdaptiveNavScaffold({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    required this.body,
    this.header,
  });

  final List<NavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget body;

  /// Shown at the top of the rail or drawer (e.g. company name).
  final Widget? header;

  static const maxBottomBarItems = 5;

  Future<void> _showMore(BuildContext context, int from) async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (header != null)
              Padding(padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.sm), child: header),
            for (var i = from; i < items.length; i++)
              ListTile(
                leading: Icon(i == selectedIndex ? items[i].selectedIcon : items[i].icon),
                title: Text(items[i].label),
                selected: i == selectedIndex,
                onTap: () => Navigator.of(sheet).pop(i),
              ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
    if (chosen != null) onSelected(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final size = windowSizeOf(context);
    final title = Text(items[selectedIndex].label);

    if (size == WindowSize.compact) {
      NavigationDestination dest(NavItem item) =>
          NavigationDestination(icon: Icon(item.icon), selectedIcon: Icon(item.selectedIcon), label: item.label);

      if (items.length <= maxBottomBarItems) {
        return Scaffold(
          appBar: AppBar(title: title),
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: onSelected,
            destinations: [for (final item in items) dest(item)],
          ),
        );
      }

      // Too many for one bar: the first four, plus "More" for the rest.
      const primary = maxBottomBarItems - 1;
      final inMore = selectedIndex >= primary;
      return Scaffold(
        appBar: AppBar(title: title),
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: inMore ? primary : selectedIndex,
          onDestinationSelected: (i) => i < primary ? onSelected(i) : _showMore(context, primary),
          destinations: [
            for (final item in items.take(primary)) dest(item),
            NavigationDestination(
              icon: const Icon(Icons.more_horiz),
              selectedIcon: Icon(inMore ? items[selectedIndex].selectedIcon : Icons.more_horiz),
              label: inMore ? items[selectedIndex].label : 'More',
            ),
          ],
        ),
      );
    }

    final extended = size == WindowSize.expanded;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              extended: extended,
              selectedIndex: selectedIndex,
              onDestinationSelected: onSelected,
              labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
              leading: extended && header != null
                  ? SizedBox(width: 200, child: Padding(padding: const EdgeInsets.all(AppSpacing.sm), child: header))
                  : null,
              destinations: [
                for (final item in items)
                  NavigationRailDestination(
                      icon: Icon(item.icon), selectedIcon: Icon(item.selectedIcon), label: Text(item.label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Scaffold(appBar: AppBar(title: title), body: body),
            ),
          ],
        ),
      ),
    );
  }
}
