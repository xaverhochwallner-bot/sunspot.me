import 'package:flutter/material.dart';

String weatherEmoji(int code) {
  if (code == 0)  return '☀️';
  if (code <= 3)  return '⛅';
  if (code <= 48) return '🌫️';
  if (code <= 67) return '🌧️';
  if (code <= 77) return '❄️';
  if (code <= 82) return '🌦️';
  return                 '⛈️';
}

Color uvColor(num uv) {
  if (uv <= 2)  return Colors.green;
  if (uv <= 5)  return Colors.yellow.shade700;
  if (uv <= 7)  return Colors.orange;
  if (uv <= 10) return Colors.red;
  return               Colors.purple;
}
