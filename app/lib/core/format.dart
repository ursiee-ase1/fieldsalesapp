import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

final _money = NumberFormat.currency(symbol: 'GH₵ ', decimalDigits: 2);
final _day = DateFormat('EEE d MMM');
final _dateTime = DateFormat('d MMM, HH:mm');

String formatMoney(num value) => _money.format(value);
String formatDay(DateTime date) => _day.format(date);
String formatDateTime(DateTime value) => _dateTime.format(value.toLocal());

/// `yyyy-MM-dd`, as Postgres `date` expects.
String isoDate(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

/// Postgres numerics arrive as int, double or string depending on the path.
num asNum(Object? value) => switch (value) {
      final num n => n,
      final String s => num.parse(s),
      _ => 0,
    };

const _uuid = Uuid();

/// Client-generated ids for sales and idempotent commands.
String newId() => _uuid.v4();
