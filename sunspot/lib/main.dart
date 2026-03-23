import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Sunshadow Map',
      home: SunMapScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class SunMapScreen extends StatefulWidget {
  const SunMapScreen({super.key});

  @override
  State<SunMapScreen> createState() => _SunMapScreenState();
}

class _SunMapScreenState extends State<SunMapScreen> {
  List<List<LatLng>> shadowPolygons = [];
  double currentHour = DateTime.now().hour.toDouble();
  double currentElevation = 0.0;
  double currentAzimuth = 0.0;
  bool isLoading = false;

  /// 🧭 Die IP des Flask-Servers:
  /// 👉 Wenn du den Android-Emulator nutzt: 10.0.2.2
  /// 👉 Wenn du ein Handy im gleichen WLAN nutzt: lokale IP (z. B. 192.168.0.23)
  static const String flaskBaseUrl = "http://127.0.0.1:5000";

  // 🧩 MultiPolygon Parser
  List<List<LatLng>> parseMultiPolygon(dynamic geom) {
    List<List<LatLng>> result = [];

    if (geom is Map && geom['coordinates'] != null) {
      final type = geom['type'];
      final coords = geom['coordinates'];

      if (type == 'Polygon') {
        for (final ring in coords) {
          final points = <LatLng>[];
          for (final pt in ring) {
            if (pt is List && pt.length >= 2) {
              final lon = (pt[0] as num).toDouble();
              final lat = (pt[1] as num).toDouble();
              if (lat.abs() <= 90 && lon.abs() <= 180) {
                points.add(LatLng(lat, lon));
              }
            }
          }
          if (points.isNotEmpty) result.add(points);
        }
      } else if (type == 'MultiPolygon') {
        for (final polygon in coords) {
          for (final ring in polygon) {
            final points = <LatLng>[];
            for (final pt in ring) {
              if (pt is List && pt.length >= 2) {
                final lon = (pt[0] as num).toDouble();
                final lat = (pt[1] as num).toDouble();
                if (lat.abs() <= 90 && lon.abs() <= 180) {
                  points.add(LatLng(lat, lon));
                }
              }
            }
            if (points.isNotEmpty) result.add(points);
          }
        }
      }
    }
    return result;
  }

  // 🛰️ Schatten abrufen
  Future<void> fetchShadowPolygons() async {
  setState(() => isLoading = true);
  try {
    final uri = Uri.parse('$flaskBaseUrl/shadow?hour=${currentHour.toInt()}');
    debugPrint("📡 Anfrage an Flask: $uri");

    final response = await http.get(uri).timeout(const Duration(seconds: 10));

    debugPrint("📩 Antwortcode: ${response.statusCode}");
    debugPrint("🌍 Antwort (erste 200 Zeichen): ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}");

    if (response.statusCode == 200 && response.body.isNotEmpty) {
      final data = jsonDecode(response.body);

      final elev = (data['elevation'] as num?)?.toDouble() ?? 0.0;
      final azim = (data['azimuth'] as num?)?.toDouble() ?? 0.0;

      List<List<LatLng>> polygons = [];
      if (data['shadows'] is List) {
        for (final s in data['shadows']) {
          polygons.addAll(parseMultiPolygon(s));
        }
      }

      setState(() {
        shadowPolygons = polygons;
        currentElevation = elev;
        currentAzimuth = azim;
        isLoading = false;
      });

      debugPrint("✅ ${polygons.length} Schatten geladen (Elev=$elev°, Azim=$azim°)");
    } else {
      debugPrint('❌ Fehler: ${response.statusCode} - ${response.reasonPhrase}');
      setState(() {
        shadowPolygons = [];
        isLoading = false;
      });
    }
  } catch (e) {
    debugPrint('⚠️ Fehler beim Abrufen des Schattens: $e');
    setState(() {
      shadowPolygons = [];
      isLoading = false;
    });
  }
}


  @override
  void initState() {
    super.initState();
    fetchShadowPolygons();
  }

  @override
  Widget build(BuildContext context) {
    final center = shadowPolygons.isNotEmpty
        ? shadowPolygons.first.first
        : const LatLng(48.2082, 16.3738);

    return Scaffold(
      appBar: AppBar(
        title: const Text('☀️ Sunshadow Map'),
        backgroundColor: Colors.orangeAccent,
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: 17.0,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.sunshadow',
                    ),
                    PolygonLayer(
                      key: ValueKey(currentHour),
                      polygons: shadowPolygons
                          .map(
                            (pts) => Polygon(
                              points: pts,
                              color: Colors.black.withOpacity(0.35),
                              borderStrokeWidth: 0.3,
                              borderColor: Colors.black26,
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
                if (isLoading)
                  const Center(
                    child: CircularProgressIndicator(
                      color: Colors.orangeAccent,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            color: Colors.orange.shade50,
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                Text(
                  '🕒 Stunde: ${currentHour.toInt()} Uhr',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  '☀️ Elevation: ${currentElevation.toStringAsFixed(1)}°, '
                  'Azimuth: ${currentAzimuth.toStringAsFixed(1)}°',
                  style: const TextStyle(fontSize: 14),
                ),
                Slider(
                  value: currentHour,
                  min: 0,
                  max: 23,
                  divisions: 23,
                  label: "${currentHour.toInt()} Uhr",
                  activeColor: Colors.orangeAccent,
                  onChanged: (value) {
                    setState(() {
                      currentHour = value;
                    });
                  },
                  onChangeEnd: (value) {
                    fetchShadowPolygons();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
