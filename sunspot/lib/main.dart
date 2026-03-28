import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
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

class _SunMapScreenState extends State<SunMapScreen> with SingleTickerProviderStateMixin {
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
  bool     _animating      = false;
  int      _animSpeed      = 1;   // 1, 2, or 4
  bool     _draggingSlider = false;
  String?  _errorMessage;

  double              _loadingProgress = 0.0;
  String              _loadingStage    = '';
  bool                _showPill        = false;  // only true after 150ms delay
  Timer?              _pillTimer;
  html.EventSource?   _activeEventSource;
  int                 _fetchGen        = 0;
  Completer<void>?    _fetchCompleter;
  bool                _shadowLayersReady = false;

  // Search
  final TextEditingController _searchController = TextEditingController();
  final FocusNode             _searchFocus      = FocusNode();
  List<Map<String, dynamic>>  _searchResults    = [];
  bool                        _searchLoading    = false;
  Timer?                      _searchDebounce;

  late final AnimationController _sunSpinCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

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

  // Used by TweenAnimationBuilder — accepts fractional hours during animation
  String _formatDisplayHour(double h) {
    final totalMinutes = (h * 60).round() % (24 * 60);
    final hour   = totalMinutes ~/ 60;
    final minute = totalMinutes % 60;
    final period = hour < 12 ? 'AM' : 'PM';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$displayHour:${minute.toString().padLeft(2, '0')} $period';
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
    _shadowLayersReady = false;  // style reload clears all layers
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
  // Geolocation
  // -------------------------------------------------------------------------

  void _goToMyLocation() async {
    try {
      final pos = await html.window.navigator.geolocation.getCurrentPosition();
      final lat = (pos.coords!.latitude  as num).toDouble();
      final lon = (pos.coords!.longitude as num).toDouble();
      final newPos = LatLng(lat, lon);
      setState(() => _currentCenter = newPos);
      final zoom = _mapController?.cameraPosition?.zoom ?? 16.5;
      await _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: newPos, zoom: zoom)),
      );
      fetchShadows();
    } catch (_) {
      _showError('Location access denied or unavailable');
    }
  }

  // -------------------------------------------------------------------------
  // Error display
  // -------------------------------------------------------------------------

  void _showError(String msg) {
    setState(() => _errorMessage = msg);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _errorMessage = null);
    });
  }

  // -------------------------------------------------------------------------
  // Shadow fetch
  // -------------------------------------------------------------------------

  Future<void> fetchShadows() async {
    if (!_mapReady || _mapController == null) return;

    _activeEventSource?.close();
    _activeEventSource = null;
    _pillTimer?.cancel();
    // Complete previous completer so any awaiting caller (animation) unblocks
    if (_fetchCompleter != null && !_fetchCompleter!.isCompleted) {
      _fetchCompleter!.complete();
    }
    final completer = Completer<void>();
    _fetchCompleter = completer;
    final gen = ++_fetchGen;

    setState(() {
      _loading         = true;
      _loadingProgress = 0.0;
      _loadingStage    = '';
      _showPill        = false;
    });

    // Only show the pill if loading takes longer than 150ms (skips cached hits)
    _pillTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted && _loading) setState(() => _showPill = true);
    });

    try {
      final bounds = await _mapController!.getVisibleRegion();
      final zoom   = (_mapController!.cameraPosition?.zoom ?? 15.0).toInt();
      final uri = Uri.parse(
        '$flaskBaseUrl/shadow/stream'
        '?lat=${_currentCenter.latitude}'
        '&lon=${_currentCenter.longitude}'
        '&hour=${_hour.toInt()}'
        '&month=${_selectedDate.month}'
        '&day=${_selectedDate.day}'
        '&zoom=$zoom'
        '&minLat=${bounds.southwest.latitude}'
        '&minLon=${bounds.southwest.longitude}'
        '&maxLat=${bounds.northeast.latitude}'
        '&maxLon=${bounds.northeast.longitude}',
      );

      final es = html.EventSource(uri.toString());
      _activeEventSource = es;

      es.onMessage.listen((event) async {
        if (gen != _fetchGen) { es.close(); return; }

        final data  = jsonDecode(event.data as String) as Map<String, dynamic>;
        final pct   = (data['progress'] as num?)?.toDouble() ?? 0.0;
        final stage = data['stage'] as String? ?? '';

        if (mounted) setState(() {
          _loadingProgress = pct / 100.0;
          _loadingStage    = stage;
        });

        if (data.containsKey('result')) {
          es.close();
          _activeEventSource = null;
          final result = data['result'] as Map<String, dynamic>;
          final elev   = (result['elevation'] as num?)?.toDouble() ?? 0.0;
          final azim   = (result['azimuth']   as num?)?.toDouble() ?? 0.0;
          if (result['dark_area'] != null) {
            await _updateMapLayers(result['dark_area'] as Map<String, dynamic>, elev);
          }
          _pillTimer?.cancel();
          if (mounted) setState(() {
            _elevation = elev;
            _azimuth   = azim;
            _loading   = false;
            _showPill  = false;
            _hasData   = true;
          });
          if (!completer.isCompleted) completer.complete();
        }

        if (data.containsKey('error')) {
          es.close();
          _activeEventSource = null;
          _pillTimer?.cancel();
          _showError(data['error'] as String? ?? 'Server error');
          if (mounted) setState(() { _loading = false; _showPill = false; _loadingProgress = 0.0; });
          if (!completer.isCompleted) completer.complete();
        }
      });

      es.onError.listen((_) {
        if (gen != _fetchGen) return;
        es.close();
        _activeEventSource = null;
        _pillTimer?.cancel();
        _showError('Could not load shadows — is the server running?');
        if (mounted) setState(() { _loading = false; _showPill = false; _loadingProgress = 0.0; });
        if (!completer.isCompleted) completer.complete();
      });

      return completer.future;

    } catch (e) {
      debugPrint('Fetch error: $e');
      _showError('Could not load shadows — is the server running?');
      if (mounted) setState(() { _loading = false; _loadingProgress = 0.0; });
      if (!completer.isCompleted) completer.complete();
    }
  }

  Future<void> _updateMapLayers(Map<String, dynamic> geoJson, double elevation) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    final t   = elevation <= 0 ? 1.0 : (elevation.clamp(0.0, 60.0) / 60.0);
    final opL0 = elevation <= 0 ? 0.82 : 0.20 + t * 0.10;
    final opL1 = elevation <= 0 ? 0.0  : 0.22 + t * 0.13;
    final opL2 = elevation <= 0 ? 0.0  : 0.24 + t * 0.16;

    if (_shadowLayersReady) {
      // Update source data + opacity in-place — no remove/re-add, no flicker
      await ctrl.setGeoJsonSource('dark-area', geoJson);
      await ctrl.setLayerProperties('shadow-l0-fill', FillLayerProperties(fillColor: '#4a6d8a', fillOpacity: opL0));
      await ctrl.setLayerProperties('shadow-l1-fill', FillLayerProperties(fillColor: '#3d5f7d', fillOpacity: opL1));
      await ctrl.setLayerProperties('shadow-l2-fill', FillLayerProperties(fillColor: '#2d4862', fillOpacity: opL2));
      return;
    }

    // First time (or after style reload): create source and layers
    await ctrl.addSource('dark-area', GeojsonSourceProperties(data: geoJson));

    // Three concentric rings — topo-map style shadow density:
    //   l0 (widest)  → light tint, shadow edges
    //   l1 (middle)  → medium, stacks on l0
    //   l2 (core)    → darkest, stacks on l0+l1
    // Result: edge zones ≈ 0.25 opacity, deep shadow cores ≈ 0.65 opacity.
    await ctrl.addLayer(
      'dark-area', 'shadow-l0-fill',
      FillLayerProperties(fillColor: '#4a6d8a', fillOpacity: opL0),
      filter: ['==', ['get', 'layer'], 'shadow-l0'],
    );
    await ctrl.addLayer(
      'dark-area', 'shadow-l1-fill',
      FillLayerProperties(fillColor: '#3d5f7d', fillOpacity: opL1),
      filter: ['==', ['get', 'layer'], 'shadow-l1'],
    );
    await ctrl.addLayer(
      'dark-area', 'shadow-l2-fill',
      FillLayerProperties(fillColor: '#2d4862', fillOpacity: opL2),
      filter: ['==', ['get', 'layer'], 'shadow-l2'],
    );
    _shadowLayersReady = true;
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
    final ms = _animSpeed == 4 ? 0 : (_animSpeed == 2 ? 200 : 500);
    if (ms > 0) await Future.delayed(Duration(milliseconds: ms));
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
    _pillTimer?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _sunSpinCtrl.dispose();
    _activeEventSource?.close();
    if (_fetchCompleter != null && !_fetchCompleter!.isCompleted) {
      _fetchCompleter!.complete();
    }
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Address search (Nominatim)
  // -------------------------------------------------------------------------

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () => _runSearch(query.trim()));
  }

  Future<void> _runSearch(String query) async {
    setState(() => _searchLoading = true);
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}&format=json&limit=5&addressdetails=1',
      );
      final resp = await http.get(uri, headers: {'User-Agent': 'Sunspot.me/1.0'});
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as List;
        setState(() => _searchResults = data.cast<Map<String, dynamic>>());
      }
    } catch (_) {
      // silently ignore network errors during search
    } finally {
      setState(() => _searchLoading = false);
    }
  }

  void _selectSearchResult(Map<String, dynamic> result) {
    final lat = double.parse(result['lat'] as String);
    final lon = double.parse(result['lon'] as String);
    final name = result['display_name'] as String;
    final target = LatLng(lat, lon);
    _searchController.text = name.split(',').first.trim();
    setState(() {
      _searchResults = [];
      _currentCenter = target;
    });
    _searchFocus.unfocus();
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: 16.0)),
    );
    fetchShadows();
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


          // Address search bar + results
          Positioned(
            top: 12, left: 12, right: 292,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.search, color: Colors.grey.shade500, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocus,
                          onChanged: _onSearchChanged,
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Search address or place…',
                            hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                      if (_searchLoading)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange.shade400),
                          ),
                        )
                      else if (_searchController.text.isNotEmpty)
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              setState(() => _searchResults = []);
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Icon(Icons.close, color: Colors.grey.shade400, size: 18),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_searchResults.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.12),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: _searchResults.asMap().entries.map((entry) {
                        final i      = entry.key;
                        final result = entry.value;
                        final parts  = (result['display_name'] as String).split(',');
                        final title  = parts.first.trim();
                        final sub    = parts.length > 1
                            ? parts.skip(1).take(2).map((s) => s.trim()).join(', ')
                            : '';
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (i > 0) Divider(height: 1, color: Colors.grey.shade100),
                            InkWell(
                              onTap: () => _selectSearchResult(result),
                              mouseCursor: SystemMouseCursors.click,
                              borderRadius: BorderRadius.vertical(
                                top:    i == 0 ? const Radius.circular(12) : Radius.zero,
                                bottom: i == _searchResults.length - 1 ? const Radius.circular(12) : Radius.zero,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                child: Row(
                                  children: [
                                    Icon(Icons.location_on_outlined, size: 16, color: Colors.grey.shade500),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                          if (sub.isNotEmpty)
                                            Text(sub, style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                                                maxLines: 1, overflow: TextOverflow.ellipsis),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ),
          ),

          // Loading bar — determinate when progress is known
          if (_loading)
            Positioned(
              top: 0, left: 0, right: 280,
              child: LinearProgressIndicator(
                value: _loadingProgress > 0 ? _loadingProgress : null,
                minHeight: 3,
                backgroundColor: Colors.transparent,
                color: Colors.orangeAccent,
              ),
            ),

          // Loading pill — bottom-center of map area
          Positioned(
            bottom: 24, left: 0, right: 280,
            child: Center(child: _buildLoadingPill()),
          ),

          // Geolocation button
          Positioned(
            bottom: 24, left: 16,
            child: FloatingActionButton.small(
              onPressed: _goToMyLocation,
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              elevation: 2,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _loading
                    ? RotationTransition(
                        key: const ValueKey('spin'),
                        turns: _sunSpinCtrl,
                        child: const Icon(Icons.wb_sunny, size: 20, color: Colors.orange),
                      )
                    : const Icon(Icons.my_location, size: 20, key: ValueKey('loc')),
              ),
            ),
          ),

          // Error banner
          if (_errorMessage != null)
            Positioned(
              bottom: 80, left: 16, right: 296,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.shade700,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_errorMessage!,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
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

  Widget _buildLoadingPill() {
    return AnimatedOpacity(
      opacity: _showPill ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      child: IgnorePointer(
        ignoring: !_showPill,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.94),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.16),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RotationTransition(
                    turns: _sunSpinCtrl,
                    child: const Icon(Icons.wb_sunny, color: Colors.orange, size: 16),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _loadingStage.isEmpty ? 'Loading…' : _loadingStage,
                    style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500, color: Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${(_loadingProgress * 100).toInt()}%',
                    style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold, color: Colors.orange,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              SizedBox(
                width: 210,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _loadingProgress > 0 ? _loadingProgress : null,
                    minHeight: 5,
                    backgroundColor: Colors.orange.shade100,
                    color: Colors.orange,
                  ),
                ),
              ),
            ],
          ),
        ),
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
              const SizedBox(height: 2),
              _buildSunSummary(),
              const SizedBox(height: 2),
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
        TweenAnimationBuilder<double>(
          tween: Tween(begin: _hour, end: _hour),  // begin=_hour: no sweep-from-midnight on load; subsequent changes animate from current value
          duration: const Duration(milliseconds: 350),
          builder: (context, value, _) {
            return Text(
              _formatDisplayHour(value),
              style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold,
                color: _draggingSlider ? Colors.orange : Colors.black87,
              ),
            );
          },
        ),
      ],
    );
  }

  // ---- Compact sun summary (always visible under time header) ----
  Widget _buildSunSummary() {
    if (_elevation == 0.0 && _azimuth == 0.0) return const SizedBox.shrink();
    final label = _elevation <= 0
        ? 'Below horizon'
        : '${_elevation.toStringAsFixed(1)}°  ·  ${_azimuth.toStringAsFixed(0)}° ${_azimuthDirection(_azimuth)}';
    return Row(
      children: [
        Icon(
          _elevation <= 0 ? Icons.nightlight_round : Icons.wb_sunny_outlined,
          size: 12, color: Colors.grey,
        ),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
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
            onChanged:  (v) => setState(() { _hour = v; _draggingSlider = true; }),
            onChangeEnd: (_) { setState(() => _draggingSlider = false); fetchShadows(); },
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
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
        ),
        const SizedBox(height: 6),
        Row(
          children: [1, 2, 4].map((speed) {
            final selected = _animSpeed == speed;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => _animSpeed = speed),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: selected ? Colors.orange : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${speed}x',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : Colors.black54,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
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
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
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
        _legendItem(color: const Color(0xAA3d5f7d),               label: 'Shadow zone'),
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
