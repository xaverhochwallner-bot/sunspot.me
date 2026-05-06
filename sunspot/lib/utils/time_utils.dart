import 'package:flutter/material.dart';

String formatDisplayHour(double h) {
  final totalMinutes = (h * 60).round() % (24 * 60);
  final hour   = totalMinutes ~/ 60;
  final minute = totalMinutes % 60;
  final period = hour < 12 ? 'AM' : 'PM';
  final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
  return '$displayHour:${minute.toString().padLeft(2, '0')} $period';
}

String timePeriod(double hour) {
  final h = hour.toInt();
  if (h >= 5  && h < 12) return 'Morning';
  if (h >= 12 && h < 17) return 'Afternoon';
  if (h >= 17 && h < 21) return 'Evening';
  return 'Night';
}

IconData timePeriodIcon(String period) {
  switch (period) {
    case 'Morning':   return Icons.wb_sunny_outlined;
    case 'Afternoon': return Icons.wb_sunny;
    case 'Evening':   return Icons.wb_twilight;
    default:          return Icons.nightlight_round;
  }
}

// Vienna local time — handles CET (UTC+1) / CEST (UTC+2) without a package.
DateTime viennaNow() {
  final utc = DateTime.now().toUtc();
  return utc.add(Duration(hours: isViennaDst(utc) ? 2 : 1));
}

bool isViennaDst(DateTime utc) {
  if (utc.month > 3 && utc.month < 10) return true;
  if (utc.month < 3 || utc.month > 10) return false;
  final lastSun = lastSundayOf(utc.year, utc.month);
  return utc.month == 3 ? utc.day >= lastSun : utc.day < lastSun;
}

int lastSundayOf(int year, int month) {
  var d = DateTime.utc(year, month + 1, 0);
  while (d.weekday != DateTime.sunday) d = d.subtract(const Duration(days: 1));
  return d.day;
}

// ISO date string used in API calls: "2024-06-15"
String formatDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
