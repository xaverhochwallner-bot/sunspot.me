import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// Berechnet das Schattenpolygon eines Gebäudes anhand:
/// - Gebäudemitte
/// - Gebäudehöhe (Meter)
/// - Sonnen-Azimut (Grad)
/// - Sonnen-Elevation (Grad)
List<LatLng> calculateShadowPolygon({
  required LatLng buildingCenter,
  required double buildingHeight,
  required double azimuthDeg,
  required double elevationDeg,
}) {
  // Hausgröße in Metern (für einfache Visualisierung)
  const double buildingSize = 10.0;

  // Länge des Schattens in Metern:
  // Wenn die Sonne tief steht, wird der Schatten länger.
  final double shadowLength =
      elevationDeg > 1 ? buildingHeight / math.tan(elevationDeg * math.pi / 180) : 1000;

  // Azimut: 0° = Norden, 90° = Osten
  final double azimuthRad = (azimuthDeg) * math.pi / 180.0;

  // Umrechnung: 1° ~ 111000 m (Breitengrad), Longitude hängt von Breite ab
  const double metersPerDegLat = 111000;
  final double metersPerDegLon =
      111000 * math.cos(buildingCenter.latitude * math.pi / 180);

  // Gebäude-Ecken (quadratisch angenommen)
  final double half = buildingSize / 2;
  final List<LatLng> building = [
    LatLng(buildingCenter.latitude + half / metersPerDegLat,
        buildingCenter.longitude - half / metersPerDegLon),
    LatLng(buildingCenter.latitude + half / metersPerDegLat,
        buildingCenter.longitude + half / metersPerDegLon),
    LatLng(buildingCenter.latitude - half / metersPerDegLat,
        buildingCenter.longitude + half / metersPerDegLon),
    LatLng(buildingCenter.latitude - half / metersPerDegLat,
        buildingCenter.longitude - half / metersPerDegLon),
  ];

  // Richtung des Schattens (vom Haus weg)
  final double dx = math.sin(azimuthRad) * shadowLength / metersPerDegLon;
  final double dy = math.cos(azimuthRad) * shadowLength / metersPerDegLat;

  // Schattenpolygon: Haus + verschobene Ecken
  final List<LatLng> shadow = [
    building[0],
    building[1],
    LatLng(building[1].latitude + dy, building[1].longitude + dx),
    LatLng(building[0].latitude + dy, building[0].longitude + dx),
    building[0], // schließt Polygon
  ];

  return shadow;
}
