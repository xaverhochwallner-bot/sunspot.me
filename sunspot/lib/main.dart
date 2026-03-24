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
  static const String flaskBaseUrl = 'http://127.0.0.1:5000';
  static const String mapStyle     = 'https://tiles.openfreemap.org/styles/bright';

  MaplibreMapController? _mapController;
  LatLng _currentCenter = const LatLng(48.2082, 16.3738);
  Timer? _debounceTimer;

  double   _hour          = DateTime.now().hour.toDouble();
  DateTime _selectedDate  = DateTime.now();
  double   _elevation     = 0.0;
  double   _azimuth       = 0.0;
  bool     _loading       = false;
  bool     _mapReady      = false;
  bool     _hasData       = false;
  bool     _animating     = false;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  String get _formattedTime {
    final h = _hour.toInt();
    if (h == 0)  return '12:00 AM';
    if (h < 12)  return '$h:00 AM';
    if (h == 12) return '12:00 PM';
    return '${h - 12}:00 PM';
  }

  String get _timePeriod {
    final h = _hour.toInt();
    if (h >= 5  && h < 12) return 'MORNING';
    if (h >= 12 && h < 17) return 'AFTERNOON';
    if (h >= 17 && h < 21) return 'EVENING';
    return 'NIGHT';
  }

  IconData get _timePeriodIcon {
    switch (_timePeriod) {
      case 'MORNING':   return Icons.wb_sunny_outlined;
      case 'AFTERNOON': return Icons.wb_sunny;
      case 'EVENING':   return Icons.wb_twilight;
      default:          return Icons.nightlight_round;
    }
  }

  String _azimuthDirection(double az) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return dirs[((az + 22.5) / 45).floor() % 8];
  }

  String get _formattedDate {
    return '${_selectedDate.day.toString().padLeft(2, '0')}.'
           '${_selectedDate.month.toString().padLeft(2, '0')}.'
           '${_selectedDate.year}';
  }

  // -------------------------------------------------------------------------
  // Map callbacks
  // -------------------------------------------------------------------------

  void _onMapCreated(MaplibreMapController controller) {
    _mapController = controller;
  }

  Future<void> _onStyleLoaded() async {
    _mapReady = true;
    fetchShadows();
  }

  void _onCameraIdle() {
    if (_mapController == null) return;
    final center = _mapController!.cameraPosition?.target;
    if (center == null) return;
    _currentCenter = center;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), fetchShadows);
  }

  // -------------------------------------------------------------------------
  // Shadow fetch
  // -------------------------------------------------------------------------

  Future<void> fetchShadows() async {
    if (!_mapReady || _mapController == null) return;
    setState(() => _loading = true);

    try {
      final bounds = await _mapController!.getVisibleRegion();
      final uri = Uri.parse(
        '$flaskBaseUrl/shadow'
        '?lat=${_currentCenter.latitude}'
        '&lon=${_currentCenter.longitude}'
        '&hour=${_hour.toInt()}'
        '&month=${_selectedDate.month}'
        '&day=${_selectedDate.day}'
        '&minLat=${bounds.southwest.latitude}'
        '&minLon=${bounds.southwest.longitude}'
        '&maxLat=${bounds.northeast.latitude}'
        '&maxLon=${bounds.northeast.longitude}',
      );

      final response = await http.get(uri).timeout(const Duration(seconds: 120));

      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final data = jsonDecode(response.body);
        final elev = (data['elevation'] as num?)?.toDouble() ?? 0.0;
        final azim = (data['azimuth']  as num?)?.toDouble() ?? 0.0;

        if (data['dark_area'] != null) {
          await _updateMapLayers(data['dark_area'] as Map<String, dynamic>);
        }

        setState(() {
          _elevation = elev;
          _azimuth   = azim;
          _loading   = false;
          _hasData   = true;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('Fetch error: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _updateMapLayers(Map<String, dynamic> geoJson) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    try { await ctrl.removeLayer('shadow-fill'); } catch (_) {}
    try { await ctrl.removeSource('dark-area');  } catch (_) {}

    await ctrl.addSource('dark-area', GeojsonSourceProperties(data: geoJson));

    await ctrl.addLayer(
      'dark-area', 'shadow-fill',
      FillLayerProperties(fillColor: '#1a2535', fillOpacity: 0.75),
      filter: ['==', ['get', 'layer'], 'shadow'],
    );
  }

  // -------------------------------------------------------------------------
  // Animation
  // -------------------------------------------------------------------------

  void _toggleAnimation() {
    if (_animating) {
      setState(() => _animating = false);
    } else {
      setState(() => _animating = true);
      _runAnimationStep();
    }
  }

  Future<void> _runAnimationStep() async {
    if (!_animating) return;
    setState(() => _hour = (_hour + 1) % 24);
    await fetchShadows();
    await Future.delayed(const Duration(milliseconds: 500));
    if (_animating) _runAnimationStep();
  }

  // -------------------------------------------------------------------------
  // Date picker
  // -------------------------------------------------------------------------

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
      fetchShadows();
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Full-screen map
          MaplibreMap(
            styleString: mapStyle,
            initialCameraPosition: CameraPosition(
              target: _currentCenter,
              zoom: 16.5,
            ),
            onMapCreated:          _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onCameraIdle:          _onCameraIdle,
            trackCameraPosition:   true,
          ),


          // Loading spinner
          if (_loading)
            const Center(
              child: CircularProgressIndicator(color: Colors.orangeAccent),
            ),

          // Right-side panel
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: 280,
            child: _buildPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 12,
            offset: const Offset(-4, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTimeHeader(),
              const SizedBox(height: 4),
              _buildTimeSlider(),
              const SizedBox(height: 12),
              _buildAnimateButton(),
              const SizedBox(height: 16),
              _buildDateSection(),
              const Divider(height: 28),
              _buildSunPosition(),
              const Divider(height: 28),
              _buildLegend(),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Time header ----
  Widget _buildTimeHeader() {
    return Row(
      children: [
        Icon(_timePeriodIcon, color: Colors.orange, size: 18),
        const SizedBox(width: 6),
        Text(_timePeriod,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: Colors.grey, letterSpacing: 1.2)),
        const Spacer(),
        Text(_formattedTime,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold)),
      ],
    );
  }

  // ---- Time slider ----
  Widget _buildTimeSlider() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: const [
          Icon(Icons.access_time, size: 14, color: Colors.grey),
          SizedBox(width: 4),
          Text('Time of Day',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.orange,
            inactiveTrackColor: Colors.orange.shade100,
            thumbColor: Colors.white,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            overlayColor: Colors.orange.withOpacity(0.2),
          ),
          child: Slider(
            value: _hour,
            min: 0,
            max: 23,
            divisions: 23,
            onChanged: (v) => setState(() => _hour = v),
            onChangeEnd: (_) => fetchShadows(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('12 AM', style: TextStyle(fontSize: 10, color: Colors.grey)),
              Text('6 AM',  style: TextStyle(fontSize: 10, color: Colors.grey)),
              Text('12 PM', style: TextStyle(fontSize: 10, color: Colors.grey)),
              Text('6 PM',  style: TextStyle(fontSize: 10, color: Colors.grey)),
              Text('12 AM', style: TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Animate button ----
  Widget _buildAnimateButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _toggleAnimation,
        icon: Icon(_animating ? Icons.stop : Icons.play_arrow, size: 18),
        label: Text(_animating ? 'Stop animation' : 'Animate shadows'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.black87,
          side: const BorderSide(color: Colors.black26),
          padding: const EdgeInsets.symmetric(vertical: 10),
          textStyle: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }

  // ---- Date section ----
  Widget _buildDateSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: const [
          Icon(Icons.calendar_today, size: 14, color: Colors.grey),
          SizedBox(width: 4),
          Text('Date', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: _pickDate,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formattedDate,
                    style: const TextStyle(fontSize: 14)),
                const Icon(Icons.calendar_month, size: 18, color: Colors.grey),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---- Sun position ----
  Widget _buildSunPosition() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('SUN POSITION',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: Colors.grey, letterSpacing: 1.2)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _sunCard(
            label: 'ELEVATION',
            icon: Icons.trending_up,
            value: '${_elevation.toStringAsFixed(1)}°',
          )),
          const SizedBox(width: 8),
          Expanded(child: _sunCard(
            label: 'AZIMUTH',
            icon: Icons.explore_outlined,
            value: '${_azimuth.toStringAsFixed(0)}° ${_azimuthDirection(_azimuth)}',
          )),
        ]),
      ],
    );
  }

  Widget _sunCard({required String label, required IconData icon, required String value}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 12, color: Colors.grey),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    fontSize: 10, color: Colors.grey,
                    fontWeight: FontWeight.w600, letterSpacing: 0.8)),
          ]),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ---- Legend ----
  Widget _buildLegend() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('LEGEND',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: Colors.grey, letterSpacing: 1.2)),
        const SizedBox(height: 10),
        _legendItem(color: const Color(0x00000000), border: true,  label: 'Sunlit area (map colors)'),
        const SizedBox(height: 6),
        _legendItem(color: const Color(0xBF1a2535),               label: 'Shadow zone'),
      ],
    );
  }

  Widget _legendItem({required Color color, bool border = false, required String label}) {
    return Row(
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: border ? Colors.white : color,
            shape: BoxShape.circle,
            border: border
                ? Border.all(color: Colors.grey.shade400, width: 1.5)
                : null,
          ),
        ),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}
