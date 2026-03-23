// lib/sun_utils.dart
import 'dart:math';

class SunPosition {
  final double azimuth;
  final double elevation;

  SunPosition({required this.azimuth, required this.elevation});
}

SunPosition getSunPosition(DateTime time, double latitude, double longitude) {
  // Berechnung des Tages des Jahres
  int dayOfYear = time.difference(DateTime(time.year, 1, 1)).inDays + 1;

  // Sonnen-Deklination (δ)
  double declination = -23.44 * cos((360 / 365) * (dayOfYear + 10) * pi / 180);

  // Stunde in Dezimal
  double solarTime = time.hour + time.minute / 60 + time.second / 3600;

  // Hour Angle (H)
  double hourAngle = 15 * (solarTime - 12);

  // Elevation
  double elevation = asin(
    sin(declination * pi / 180) * sin(latitude * pi / 180) +
    cos(declination * pi / 180) * cos(latitude * pi / 180) * cos(hourAngle * pi / 180)
  ) * 180 / pi;

  // Azimut
  double azimuth = acos(
    (sin(declination * pi / 180) - sin(elevation * pi / 180) * sin(latitude * pi / 180)) /
    (cos(elevation * pi / 180) * cos(latitude * pi / 180))
  ) * 180 / pi;

  if (hourAngle > 0) {
    azimuth = 360 - azimuth;
  }

  return SunPosition(azimuth: azimuth, elevation: elevation);
}
