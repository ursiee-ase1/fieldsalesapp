import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';
import 'tokens.dart';

// Small chart kit in plain widgets. Rules: one series per chart in the
// theme's primary colour (the title names it, so no legend); thin marks with
// rounded data ends; values in text colours, never the mark colour; exact
// values on hover/long-press; every trend has a table view.

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.caption, this.icon});

  final String label;
  final String value;
  final String? caption;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 18, color: muted), const SizedBox(width: AppSpacing.xs)],
              Expanded(child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: muted))),
            ]),
            const SizedBox(height: AppSpacing.sm),
            Text(value, style: theme.textTheme.headlineSmall),
            if (caption != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(caption!, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lays tiles out in as many columns as fit (min tile width ~170).
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final columns = math.max(1, math.min(children.length, (c.maxWidth / 170).floor()));
      final width = (c.maxWidth - (columns - 1) * AppSpacing.md) / columns;
      return Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.md,
        children: [for (final child in children) SizedBox(width: width, child: child)],
      );
    });
  }
}

class BarDatum {
  const BarDatum(this.label, this.value, this.valueLabel);
  final String label;
  final num value;
  final String valueLabel;
}

/// Ranked horizontal bars (magnitude by category), label above each bar.
class BarList extends StatelessWidget {
  const BarList({super.key, required this.items, this.emptyText = 'No data for this period.'});

  final List<BarDatum> items;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (items.isEmpty) return Text(emptyText, style: theme.textTheme.bodyMedium);
    final max = items.map((i) => i.value).fold<num>(0, math.max);
    return Column(
      children: [
        for (final i in items)
          Semantics(
            label: '${i.label}: ${i.valueLabel}',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(child: Text(i.label, overflow: TextOverflow.ellipsis)),
                    Text(i.valueLabel, style: theme.textTheme.titleSmall),
                  ]),
                  const SizedBox(height: AppSpacing.xs),
                  LayoutBuilder(
                    builder: (context, c) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 10,
                        // Zero still shows as a sliver so the row reads as "none", not missing.
                        width: max <= 0 ? 2 : math.max(2, c.maxWidth * (i.value / max)),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Daily columns (change over time). Hover or long-press a column for its
/// exact value; "Show as table" gives the same data as text.
class DailyBars extends StatefulWidget {
  const DailyBars({super.key, required this.points, required this.format, this.height = 150});

  final List<ChartPoint> points;
  final String Function(num value) format;
  final double height;

  @override
  State<DailyBars> createState() => _DailyBarsState();
}

class _DailyBarsState extends State<DailyBars> {
  var _table = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final points = widget.points;
    final max = points.map((p) => p.value).fold<num>(0, math.max);
    final total = points.fold<num>(0, (s, p) => s + p.value);
    final gap = points.length > 20 ? 1.0 : 2.0;

    final chart = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Highest day: ${widget.format(max)}', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          height: widget.height,
          child: Semantics(
            label: 'Daily chart, ${points.length} days, total ${widget.format(total)}. Use "Show as table" for each day.',
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  bottom: BorderSide(color: theme.colorScheme.outline),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final p in points)
                    Expanded(
                      child: Tooltip(
                        message: '${formatDay(p.date)}: ${widget.format(p.value)}',
                        triggerMode: TooltipTriggerMode.tap,
                        child: Container(
                          // The whole column is the hit target, not just the bar.
                          color: Colors.transparent,
                          alignment: Alignment.bottomCenter,
                          padding: EdgeInsets.symmetric(horizontal: gap / 2),
                          child: FractionallySizedBox(
                            heightFactor: max <= 0 ? 0 : (p.value / max).clamp(0, 1).toDouble(),
                            child: Container(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (points.isNotEmpty)
          Row(children: [
            Text(formatDay(points.first.date), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            const Spacer(),
            Text(formatDay(points.last.date), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ]),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_table)
          DataTable(
            headingRowHeight: 36,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 36,
            columns: const [DataColumn(label: Text('Day')), DataColumn(label: Text('Value'), numeric: true)],
            rows: [
              for (final p in points.reversed)
                DataRow(cells: [DataCell(Text(formatDay(p.date))), DataCell(Text(widget.format(p.value)))]),
            ],
          )
        else
          chart,
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => setState(() => _table = !_table),
            icon: Icon(_table ? Icons.bar_chart : Icons.table_rows_outlined),
            label: Text(_table ? 'Show as chart' : 'Show as table'),
          ),
        ),
      ],
    );
  }
}

/// Lightweight point for charts, independent of any feature's models.
class ChartPoint {
  const ChartPoint(this.date, this.value);
  final DateTime date;
  final num value;
}
