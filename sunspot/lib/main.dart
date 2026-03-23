import 'dart:async';
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
  static const String flaskBaseUrl = "http://127.0.0.1:5000";
  static const int radiusMeters = 400;

  final MapController _mapController = MapController();

  List<List<LatLng>> shadowPolygons = [];
  double currentHour = DateTime.now().hour.toDouble();
  double currentElevation = 0.0;
  double currentAzimuth = 0.0;
  bool isLoading = false;

  LatLng _currentCenter = const LatLng(48.2082, 16.3738);
  Timer? _debounceTimer;

  // Parse GeoJSON Polygon / MultiPolygon into list of rings
  List<List<LatLng>> parseGeometry(dynamic geom) {
    final result = <List<LatLng>>[];
    if (geom is! Map || geom['coordinates'] == null) return result;

    List<dynamic> rings = [];
    if (geom['type'] == 'Polygon') {
      rings = geom['coordinates'] as List;
    } else if (geom['type'] == 'MultiPolygon') {
      for (final poly in geom['coordinates'] as List) {
        rings.addAll(poly as List);
      }
    }

    for (final ring in rings) {
      final points = <LatLng>[];
      for (final pt in ring as List) {
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
    return result;
  }

  Future<void> fetchShadows() async {
    setState(() => isLoading = true);
    try {
      final uri = Uri.parse(
        '$flaskBaseUrl/shadow'
        '?lat=${_currentCenter.latitude}'
        '&lon=${_currentCenter.longitude}'
        '&radius=$radiusMeters'
        '&hour=${currentHour.toInt()}',
      );
      debugPrint("Fetching: $uri");

      final response = await http.get(uri).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final data = jsonDecode(response.body);
        final elev = (data['elevation'] as num?)?.toDouble() ?? 0.0;
        final azim = (data['azimuth'] as num?)?.toDouble() ?? 0.0;

        final polygons = <List<LatLng>>[];
        if (data['shadows'] is List) {
          for (final s in data['shadows'] as List) {
            polygons.addAll(parseGeometry(s));
          }
        }

        setState(() {
          shadowPolygons = polygons;
          currentElevation = elev;
          currentAzimuth = azim;
          isLoading = false;
        });
        debugPrint("${polygons.length} shadows loaded (elev=$elev, azim=$azim)");
      } else {
        setState(() { shadowPolygons = []; isLoading = false; });
      }
    } catch (e) {
      debugPrint("Fetch error: $e");
      setState(() { shadowPolygons = []; isLoading = false; });
    }
  }

  void _onMapPositionChanged(MapCamera camera, bool hasGesture) {
    if (!hasGesture) return;
    _currentCenter = camera.center;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), fetchShadows);
  }

  @override
  void initState() {
    super.initState();
    fetchShadows();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sunshadow Map'),
        backgroundColor: Colors.orangeAccent,
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentCenter,
                    initialZoom: 17.0,
                    onPositionChanged: _onMapPositionChanged,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.sunshadow',
                    ),
                    PolygonLayer(
                      polygons: shadowPolygons
                          .map((pts) => Polygon(
                                points: pts,
                                color: Colors.black.withOpacity(0.35),
                                borderStrokeWidth: 0.3,
                                borderColor: Colors.black26,
                              ))
                          .toList(),
                    ),
                  ],
                ),
                if (isLoading)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.orangeAccent),
                  ),
              ],
            ),
          ),
          Container(
            color: Colors.orange.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                Text(
                  'Hour: ${currentHour.toInt()}:00',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Elevation: ${currentElevation.toStringAsFixed(1)}°  |  Azimuth: ${currentAzimuth.toStringAsFixed(1)}°',
                  style: const TextStyle(fontSize: 13),
                ),
                Slider(
                  value: currentHour,
                  min: 0,
                  max: 23,
                  divisions: 23,
                  label: "${currentHour.toInt()}:00",
                  activeColor: Colors.orangeAccent,
                  onChanged: (v) => setState(() => currentHour = v),
                  onChangeEnd: (_) => fetchShadows(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
