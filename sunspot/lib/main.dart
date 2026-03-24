import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

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

  static const String mapStyle =
      'https://tiles.openfreemap.org/styles/bright';

  MaplibreMapController? _mapController;
  LatLng _currentCenter = const LatLng(48.2082, 16.3738);
  Timer? _debounceTimer;

  double currentHour = DateTime.now().hour.toDouble();
  double currentElevation = 0.0;
  double currentAzimuth = 0.0;
  bool isLoading = false;
  bool _mapReady = false;
  bool _hasReceivedData = false;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onMapCreated(MaplibreMapController controller) {
    _mapController = controller;
  }

  Future<void> _onStyleLoaded() async {
    _mapReady = true;
    fetchShadows();
  }

  Future<void> fetchShadows() async {
    if (!_mapReady || _mapController == null) return;
    setState(() => isLoading = true);

    try {
      final bounds = await _mapController!.getVisibleRegion();
      final uri = Uri.parse(
        '$flaskBaseUrl/shadow'
        '?lat=${_currentCenter.latitude}'
        '&lon=${_currentCenter.longitude}'
        '&hour=${currentHour.toInt()}'
        '&minLat=${bounds.southwest.latitude}'
        '&minLon=${bounds.southwest.longitude}'
        '&maxLat=${bounds.northeast.latitude}'
        '&maxLon=${bounds.northeast.longitude}',
      );
      debugPrint("Fetching: $uri");

      final response =
          await http.get(uri).timeout(const Duration(seconds: 120));

      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final data = jsonDecode(response.body);
        final elev = (data['elevation'] as num?)?.toDouble() ?? 0.0;
        final azim = (data['azimuth'] as num?)?.toDouble() ?? 0.0;

        if (data['dark_area'] != null) {
          await _updateMapLayers(data['dark_area'] as Map<String, dynamic>);
        }

        setState(() {
          currentElevation = elev;
          currentAzimuth = azim;
          isLoading = false;
          _hasReceivedData = true;
        });
        debugPrint("Shadows updated (elev=$elev, azim=$azim)");
      } else {
        setState(() => isLoading = false);
      }
    } catch (e) {
      debugPrint("Fetch error: $e");
      setState(() => isLoading = false);
    }
  }

  Future<void> _updateMapLayers(Map<String, dynamic> darkAreaGeoJson) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    try { await ctrl.removeLayer('shadow-fill'); } catch (_) {}
    try { await ctrl.removeLayer('sunlit-ground-fill'); } catch (_) {}
    try { await ctrl.removeSource('dark-area'); } catch (_) {}

    await ctrl.addSource('dark-area', GeojsonSourceProperties(data: darkAreaGeoJson));

    // Unified dark overlay covering full viewport
    await ctrl.addLayer(
      'dark-area',
      'shadow-fill',
      FillLayerProperties(fillColor: '#1a2535', fillOpacity: 0.75),
      filter: ['==', ['get', 'layer'], 'shadow'],
    );

    // Sunlit ground (light blue)
    await ctrl.addLayer(
      'dark-area',
      'sunlit-ground-fill',
      FillLayerProperties(fillColor: '#d4eaf7', fillOpacity: 0.55),
      filter: ['==', ['get', 'layer'], 'sunlit_ground'],
    );

  }

  void _onCameraIdle() {
    if (_mapController == null) return;
    final center = _mapController!.cameraPosition?.target;
    if (center == null) return;
    _currentCenter = center;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), fetchShadows);
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
                MaplibreMap(
                  styleString: mapStyle,
                  initialCameraPosition: CameraPosition(
                    target: _currentCenter,
                    zoom: 16.5,
                    tilt: 0,
                  ),
                  onMapCreated: _onMapCreated,
                  onStyleLoadedCallback: _onStyleLoaded,
                  onCameraIdle: _onCameraIdle,
                  trackCameraPosition: true,
                ),
                if (_hasReceivedData && currentElevation <= 0 && !isLoading)
                  IgnorePointer(
                    child: Container(
                      color: Colors.black.withOpacity(0.6),
                      child: const Center(
                        child: Text(
                          '🌙 No sunlight',
                          style: TextStyle(color: Colors.white70, fontSize: 18),
                        ),
                      ),
                    ),
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
