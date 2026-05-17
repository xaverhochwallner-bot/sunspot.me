import 'dart:math';
import 'time_utils.dart';

const _d2r = pi / 180.0;
const _r2d = 180.0 / pi;

/// Sun elevation angle (degrees) for a given location and Vienna local time.
/// Positive = above horizon, negative = below horizon.
/// Uses NOAA Solar Calculator algorithm (accurate to ~0.01° for 1950–2050).
double sunElevation(double lat, double lon, int year, int month, int day, int hour, int minute) {
  final isDst = _viennaLocalIsDst(year, month, day, hour);
  // Treat Vienna local as UTC by construction, then subtract offset.
  final localAsUtc = DateTime.utc(year, month, day, hour, minute);
  final utcDt = localAsUtc.subtract(Duration(hours: isDst ? 2 : 1));
  return _elevationUtc(lat, lon, utcDt);
}

/// Sunrise and sunset as fractional Vienna local hours (e.g. 6.5 = 06:30).
/// Returns null for each if sun doesn't cross the horizon that day.
({double? sunrise, double? sunset}) sunriseSunset(
  double lat, double lon, int year, int month, int day,
) {
  double? sunrise;
  double? sunset;
  for (int h = 4; h <= 21; h++) {
    final e0 = sunElevation(lat, lon, year, month, day, h,     0);
    final e1 = sunElevation(lat, lon, year, month, day, h + 1, 0);
    if (e0 <= 0 && e1 > 0 && sunrise == null) {
      sunrise = h + e0 / (e0 - e1);
    }
    if (e0 > 0 && e1 <= 0 && sunset == null) {
      sunset = h + e0 / (e0 - e1);
    }
  }
  return (sunrise: sunrise, sunset: sunset);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

bool _viennaLocalIsDst(int year, int month, int day, int hour) {
  if (month > 3 && month < 10) return true;
  if (month < 3 || month > 10) return false;
  final lastSun = lastSundayOf(year, month);
  if (month == 3) return day > lastSun || (day == lastSun && hour >= 2);
  return day < lastSun || (day == lastSun && hour < 3);
}

double _elevationUtc(double lat, double lon, DateTime utc) {
  final jd = _julianDay(utc);
  final jc = (jd - 2451545.0) / 36525.0;

  // Geometric mean longitude (deg, 0–360)
  final L0 = (280.46646 + jc * (36000.76983 + jc * 0.0003032)) % 360;

  // Geometric mean anomaly (deg)
  final M    = 357.52911 + jc * (35999.05029 - 0.0001537 * jc);
  final Mrad = M * _d2r;

  // Eccentricity
  final e = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc);

  // Equation of center
  final C = sin(Mrad)     * (1.914602 - jc * (0.004817 + 0.000014 * jc))
          + sin(2 * Mrad) * (0.019993 - 0.000101 * jc)
          + sin(3 * Mrad) * 0.000289;

  // Sun's apparent longitude (deg)
  final omega  = 125.04 - 1934.136 * jc;
  final lambda = (L0 + C - 0.00569 - 0.00478 * sin(omega * _d2r)) * _d2r;

  // Corrected obliquity of ecliptic (rad)
  final eps0 = 23 + (26 + (21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813))) / 60) / 60;
  final eps  = (eps0 + 0.00256 * cos(omega * _d2r)) * _d2r;

  // Declination (rad)
  final decl = asin(sin(eps) * sin(lambda));

  // Equation of time (minutes)
  final y    = pow(tan(eps / 2), 2).toDouble();
  final L0r  = L0 * _d2r;
  final eot  = 4 * _r2d * (
    y * sin(2 * L0r)
    - 2 * e * sin(Mrad)
    + 4 * e * y * sin(Mrad) * cos(2 * L0r)
    - 0.5 * y * y * sin(4 * L0r)
    - 1.25 * e * e * sin(2 * Mrad)
  );

  // True solar time (minutes) and hour angle (deg)
  final utcMin = utc.hour * 60.0 + utc.minute + utc.second / 60.0;
  final tst    = (utcMin + eot + 4 * lon) % 1440;
  final ha     = (tst / 4 - 180) * _d2r;

  // Solar zenith → elevation
  final latRad = lat * _d2r;
  final cosZ   = sin(latRad) * sin(decl) + cos(latRad) * cos(decl) * cos(ha);
  final zenith = acos(cosZ.clamp(-1.0, 1.0)) * _r2d;
  final elev   = 90 - zenith;

  return elev + _refraction(elev);
}

double _refraction(double elev) {
  if (elev > 85) return 0;
  final te = tan(elev * _d2r);
  if (elev > 5) {
    return (58.1 / te - 0.07 / (te * te * te) + 0.000086 / pow(te, 5)) / 3600;
  } else if (elev > -0.575) {
    return (1735 + elev * (-518.2 + elev * (103.4 + elev * (-12.79 + elev * 0.711)))) / 3600;
  } else {
    return -20.772 / te / 3600;
  }
}

double _julianDay(DateTime utc) {
  int Y = utc.year;
  int M = utc.month;
  if (M <= 2) { Y--; M += 12; }
  final A = Y ~/ 100;
  final B = 2 - A + A ~/ 4;
  final D = utc.day + (utc.hour + utc.minute / 60.0 + utc.second / 3600.0) / 24.0;
  return (365.25 * (Y + 4716)).floor() + (30.6001 * (M + 1)).floor() + D + B - 1524.5;
}
