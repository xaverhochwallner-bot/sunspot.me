import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:geolocator/geolocator.dart';
import 'dart:math';
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

  MapLibreMapController? _mapController;
  LatLng _currentCenter = const LatLng(48.2082, 16.3738);
  Timer? _debounceTimer;

  double   _hour          = DateTime.now().hour.toDouble();
  DateTime _selectedDate  = DateTime.now();
  double   _elevation     = 0.0;
  double   _azimuth       = 0.0;
  bool     _loading       = false;
  bool     _mapReady      = false;
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
  int                 _lastFetchZoom     = -1;

  // Panel
  bool _panelOpen = true;

  // Live mode
  bool   _liveMode  = false;
  Timer? _liveTimer;

  // Sunrise / sunset (local hours, e.g. 6.0, 20.0)
  double? _sunriseHour;
  double? _sunsetHour;

  // Point info popup
  LatLng?                _clickedPoint;
  bool                   _pointInfoLoading = false;
  Map<String, dynamic>?  _pointInfo;
  bool                   _ignoreNextMapClick = false;
  bool                   _pinLayerReady = false;
  double                 _screenWidth = 1200;

  // GPS blue dot
  LatLng? _gpsPosition;
  bool    _myLocationLayerReady = false;

  // Sunny spots
  List<Map<String, dynamic>> _sunnySpots          = [];
  bool                       _sunnySpotsLayerReady = false;
  bool                       _findingSunnySpots    = false;

  // Panel scroll
  final ScrollController _panelScroll = ScrollController();

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

  void _onMapCreated(MapLibreMapController controller) {
    _mapController = controller;
  }

  void _setMapCanvasInteractive(bool interactive) {
    final pe = interactive ? '' : 'none';
    html.document.querySelectorAll('.maplibregl-canvas-container').forEach((e) {
      e.style.pointerEvents = pe;
    });
  }

  Future<void> _onStyleLoaded() async {
    _mapReady = true;
    _shadowLayersReady    = false;
    _pinLayerReady        = false;
    _myLocationLayerReady = false;
    _sunnySpotsLayerReady = false;
    _injectAttributionCss();
    fetchShadows();
    _initGpsOnStart();
  }

  void _injectAttributionCss() {
    final style = html.StyleElement();
    style.text = '.maplibregl-ctrl-bottom-right { padding-right: 4px !important; }'
        '.maplibregl-ctrl-attrib { font-size: 10px !important; }';
    html.document.head!.append(style);
  }

  void _onCameraIdle() {
    if (_mapController == null) return;
    final center = _mapController!.cameraPosition?.target;
    if (center == null) return;
    _currentCenter = center;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), fetchShadows);
  }

  void _onMapClick(Point<double> point, LatLng coordinates) {
    if (_ignoreNextMapClick) {
      _ignoreNextMapClick = false;
      return;
    }
    // Reject clicks in the panel/toggle zone
    final panelZone = _panelOpen ? 300.0 : 22.0;
    if (point.x > _screenWidth - panelZone) return;
    if (_searchResults.isNotEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() {
      _clickedPoint      = coordinates;
      _pointInfo         = null;
      _pointInfoLoading  = true;
    });
    _showPin(coordinates);
    _fetchPointInfo(coordinates);
  }

  Future<void> _fetchPointInfo(LatLng point) async {
    try {
      final d       = _selectedDate;
      final dateStr = '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
      final uri     = Uri.parse(
        '$flaskBaseUrl/point_info'
        '?lat=${point.latitude}&lon=${point.longitude}'
        '&date=$dateStr&hour=${_hour.toInt()}&minute=${((_hour * 60).toInt() % 60)}',
      );
      final resp = await http.get(uri);
      if (mounted && resp.statusCode == 200) {
        setState(() {
          _pointInfo        = jsonDecode(resp.body) as Map<String, dynamic>;
          _pointInfoLoading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_panelScroll.hasClients) {
            _panelScroll.animateTo(
              _panelScroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _pointInfoLoading = false);
    }
  }

  Future<void> _showPin(LatLng point) async {
    final ctrl = _mapController;
    if (ctrl == null) return;
    final geoJson = {
      'type': 'FeatureCollection',
      'features': [{
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [point.longitude, point.latitude]},
        'properties': {},
      }],
    };
    if (_pinLayerReady) {
      await ctrl.setGeoJsonSource('clicked-point', geoJson);
    } else {
      await ctrl.addSource('clicked-point', GeojsonSourceProperties(data: geoJson));
      await ctrl.addLayer(
        'clicked-point', 'clicked-point-outer',
        CircleLayerProperties(
          circleRadius: 12,
          circleColor: '#FF8C00',
          circleOpacity: 0.25,
          circleStrokeWidth: 0,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'clicked-point', 'clicked-point-inner',
        CircleLayerProperties(
          circleRadius: 6,
          circleColor: '#FF8C00',
          circleOpacity: 1.0,
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFFFF',
        ),
        enableInteraction: false,
      );
      _pinLayerReady = true;
    }
  }

  Future<void> _hidePin() async {
    if (!_pinLayerReady) return;
    final ctrl = _mapController;
    if (ctrl == null) return;
    await ctrl.setGeoJsonSource('clicked-point',
        {'type': 'FeatureCollection', 'features': []});
  }

  // -------------------------------------------------------------------------
  // Sunny spots
  // -------------------------------------------------------------------------

  Future<void> _findSunnySpots() async {
    final ctrl = _mapController;
    if (ctrl == null || !_mapReady) return;

    setState(() => _findingSunnySpots = true);
    try {
      final bounds = await ctrl.getVisibleRegion();
      final zoom   = ctrl.cameraPosition?.zoom ?? 15.0;
      final h      = _hour.toInt();
      final min    = ((_hour * 60).toInt() % 60);
      final date   = _selectedDate;

      final uri = Uri.parse(
        '$flaskBaseUrl/find_sunny_spots'
        '?lat=${_currentCenter.latitude}'
        '&lon=${_currentCenter.longitude}'
        '&hour=$h&minute=$min'
        '&month=${date.month}&day=${date.day}'
        '&zoom=${zoom.round()}'
        '&minLat=${bounds.southwest.latitude}'
        '&minLon=${bounds.southwest.longitude}'
        '&maxLat=${bounds.northeast.latitude}'
        '&maxLon=${bounds.northeast.longitude}'
        '&n=5',
      );

      final response = await http.get(uri).timeout(const Duration(seconds: 30));
      final data     = jsonDecode(response.body) as Map<String, dynamic>;
      final spots    = (data['spots'] as List<dynamic>? ?? [])
          .map((s) => <String, dynamic>{
                'lat':            (s['lat']  as num).toDouble(),
                'lon':            (s['lon']  as num).toDouble(),
                'sun_hours_left': (s['sun_hours_left'] as num?)?.toInt() ?? 0,
                'sun_until':      s['sun_until'] as int?,
              })
          .toList();

      setState(() => _sunnySpots = spots);
      await _showSunnySpotMarkers(spots);

      if (spots.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 150));
        _panelScroll.animateTo(
          _panelScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
        );
      }
    } catch (_) {
      _showError('Could not find sunny spots');
    } finally {
      if (mounted) setState(() => _findingSunnySpots = false);
    }
  }

  Future<void> _showSunnySpotMarkers(List<Map<String, dynamic>> spots) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    final features = spots.asMap().entries.map((e) => {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [e.value['lon'], e.value['lat']],
      },
      'properties': {'index': e.key + 1},
    }).toList();

    final geoJson = {'type': 'FeatureCollection', 'features': features};

    if (_sunnySpotsLayerReady) {
      await ctrl.setGeoJsonSource('sunny-spots', geoJson);
    } else {
      await ctrl.addSource('sunny-spots', GeojsonSourceProperties(data: geoJson));
      await ctrl.addLayer(
        'sunny-spots', 'sunny-spots-glow',
        CircleLayerProperties(
          circleRadius: 20,
          circleColor: '#FFD700',
          circleOpacity: 0.25,
          circleStrokeWidth: 0,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'sunny-spots', 'sunny-spots-dot',
        CircleLayerProperties(
          circleRadius: 8,
          circleColor: '#FFD700',
          circleOpacity: 1.0,
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFFFF',
        ),
        enableInteraction: false,
      );
      _sunnySpotsLayerReady = true;
    }
  }

  Future<void> _clearSunnySpots() async {
    setState(() => _sunnySpots = []);
    if (!_sunnySpotsLayerReady) return;
    await _mapController?.setGeoJsonSource(
        'sunny-spots', {'type': 'FeatureCollection', 'features': []});
  }

  // -------------------------------------------------------------------------
  // Geolocation
  // -------------------------------------------------------------------------

  Future<LatLng?> _getGpsPosition() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        final req = await Geolocator.requestPermission();
        if (req == LocationPermission.denied ||
            req == LocationPermission.deniedForever) {
          _showError('GPS: permission denied');
          return null;
        }
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 10));
      return LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      _showError('GPS: ${e.toString().split('\n').first}');
      return null;
    }
  }

  Future<void> _initGpsOnStart() async {
    final newPos = await _getGpsPosition();
    if (newPos == null || !mounted) return;
    setState(() {
      _gpsPosition   = newPos;
      _currentCenter = newPos;
    });
    await _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: newPos, zoom: 15.0)),
    );
    await _showMyLocationDot(newPos);
  }

  void _goToMyLocation() async {
    final newPos = await _getGpsPosition();
    if (newPos == null || !mounted) return;
    setState(() {
      _gpsPosition   = newPos;
      _currentCenter = newPos;
    });
    final zoom = _mapController?.cameraPosition?.zoom ?? 16.0;
    await _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: newPos, zoom: zoom)),
    );
    await _showMyLocationDot(newPos);
    fetchShadows();
  }

  Future<void> _showMyLocationDot(LatLng pos) async {
    final ctrl = _mapController;
    if (ctrl == null) return;
    final geoJson = {
      'type': 'FeatureCollection',
      'features': [{
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [pos.longitude, pos.latitude]},
        'properties': {},
      }],
    };
    if (_myLocationLayerReady) {
      await ctrl.setGeoJsonSource('my-location', geoJson);
    } else {
      await ctrl.addSource('my-location', GeojsonSourceProperties(data: geoJson));
      await ctrl.addLayer(
        'my-location', 'my-location-pulse',
        CircleLayerProperties(
          circleRadius: 16,
          circleColor: '#2979FF',
          circleOpacity: 0.20,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'my-location', 'my-location-dot',
        CircleLayerProperties(
          circleRadius: 7,
          circleColor: '#2979FF',
          circleOpacity: 1.0,
          circleStrokeWidth: 2.0,
          circleStrokeColor: '#FFFFFF',
          circleStrokeOpacity: 1.0,
        ),
        enableInteraction: false,
      );
      _myLocationLayerReady = true;
    }
  }

  // -------------------------------------------------------------------------
  // Error display
  // -------------------------------------------------------------------------

  // Disable/enable pointer events on the MapLibre canvas via DOM so slider
  // drags don't also pan the map (AbsorbPointer doesn't reach platform views).
  void _setMapPointerEvents(bool enabled) {
    final els = html.document.querySelectorAll('.maplibregl-canvas-container');
    for (final el in els) {
      el.style.pointerEvents = enabled ? 'auto' : 'none';
    }
  }

  void _showError(String msg) {
    setState(() => _errorMessage = msg);
    Future.delayed(const Duration(seconds: 10), () {
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
      final bounds   = await _mapController!.getVisibleRegion();
      final rawZoom  = _mapController!.cameraPosition?.zoom ?? 15.0;
      final zoom     = rawZoom.toInt();

      // Below zoom 11.5, building shadows are too fragmented — clear and skip.
      if (rawZoom < 11.5) {
        if (_shadowLayersReady) {
          final empty = <String, dynamic>{'type': 'FeatureCollection', 'features': <dynamic>[]};
          await _mapController!.setGeoJsonSource('dark-area', empty);
        }
        _pillTimer?.cancel();
        if (mounted) setState(() { _loading = false; _showPill = false; _loadingProgress = 0.0; });
        if (!completer.isCompleted) completer.complete();
        return;
      }

      if (_shadowLayersReady && _lastFetchZoom != -1 && zoom != _lastFetchZoom) {
        final zoomDelta = (zoom - _lastFetchZoom).abs();
        if (zoomDelta >= 2) {
          // Large jump — old rectangle looks obviously wrong: clear it.
          final empty = <String, dynamic>{'type': 'FeatureCollection', 'features': <dynamic>[]};
          await _mapController!.setGeoJsonSource('dark-area', empty);
        } else {
          // Small step — keep old shadow visible but dim it to signal stale data.
          await _mapController!.setLayerProperties('shadow-l0-fill', FillLayerProperties(fillColor: '#4a6d8a', fillOpacity: 0.15));
          await _mapController!.setLayerProperties('shadow-l1-fill', FillLayerProperties(fillColor: '#3d5f7d', fillOpacity: 0.10));
          await _mapController!.setLayerProperties('shadow-l2-fill', FillLayerProperties(fillColor: '#2d4862', fillOpacity: 0.08));
        }
      }

      _lastFetchZoom = zoom;

      final uri = Uri.parse(
        '$flaskBaseUrl/shadow/stream'
        '?lat=${_currentCenter.latitude}'
        '&lon=${_currentCenter.longitude}'
        '&hour=${_hour.toInt()}'
        '&minute=${((_hour * 60).toInt() % 60)}'
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
          final result  = data['result'] as Map<String, dynamic>;
          final elev    = (result['elevation'] as num?)?.toDouble() ?? 0.0;
          final azim    = (result['azimuth']   as num?)?.toDouble() ?? 0.0;
          final srHour  = (result['sunrise']   as num?)?.toDouble();
          final ssHour  = (result['sunset']    as num?)?.toDouble();
          if (result['dark_area'] != null) {
            await _updateMapLayers(result['dark_area'] as Map<String, dynamic>, elev);
          }
          _pillTimer?.cancel();
          if (mounted) {
            setState(() {
              _elevation   = elev;
              _azimuth     = azim;
              _sunriseHour = srHour;
              _sunsetHour  = ssHour;
              _loading     = false;
              _showPill    = false;
            });
          }
          if (!completer.isCompleted) completer.complete();
        }

        if (data.containsKey('error')) {
          es.close();
          _activeEventSource = null;
          _pillTimer?.cancel();
          _showError(data['error'] as String? ?? 'Server error');
          if (mounted) {
            setState(() { _loading = false; _showPill = false; _loadingProgress = 0.0; });
          }
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
      enableInteraction: false,
    );
    await ctrl.addLayer(
      'dark-area', 'shadow-l1-fill',
      FillLayerProperties(fillColor: '#3d5f7d', fillOpacity: opL1),
      filter: ['==', ['get', 'layer'], 'shadow-l1'],
      enableInteraction: false,
    );
    await ctrl.addLayer(
      'dark-area', 'shadow-l2-fill',
      FillLayerProperties(fillColor: '#2d4862', fillOpacity: opL2),
      filter: ['==', ['get', 'layer'], 'shadow-l2'],
      enableInteraction: false,
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
  // Live mode
  // -------------------------------------------------------------------------

  void _toggleLiveMode() {
    if (_liveMode) {
      _liveTimer?.cancel();
      setState(() => _liveMode = false);
    } else {
      setState(() {
        _liveMode = true;
        _animating = false;  // stop animation when going live
        _selectedDate = DateTime.now();
        final now = DateTime.now();
        _hour = (now.hour + now.minute / 60.0).clamp(0.0, 23.0);
      });
      fetchShadows();
      _liveTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (!mounted) return;
        setState(() {
          final now = DateTime.now();
          _selectedDate = now;
          _hour = (now.hour + now.minute / 60.0).clamp(0.0, 23.0);
        });
        fetchShadows();
      });
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
    _liveTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _panelScroll.dispose();
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
    _screenWidth = MediaQuery.of(context).size.width;
    return Scaffold(
      body: Stack(
        children: [
          // Full-screen map
          AbsorbPointer(
            absorbing: _draggingSlider,
            child: MapLibreMap(
              styleString: mapStyle,
              initialCameraPosition: CameraPosition(
                target: _currentCenter,
                zoom: 13.0,
              ),
              onMapCreated:          _onMapCreated,
              onStyleLoadedCallback: _onStyleLoaded,
              onCameraIdle:          _onCameraIdle,
              onMapClick:            _onMapClick,
              trackCameraPosition:   true,
              compassEnabled:        false,
            ),
          ),


          // Address search bar + results
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            top: 12, left: 12, right: _panelOpen ? 292 : 12,
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
                        color: Colors.black.withValues(alpha: 0.15),
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
                          color: Colors.black.withValues(alpha: 0.12),
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

          // Loading bar
          if (_loading)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              top: 0, left: 0, right: _panelOpen ? 280 : 0,
              child: LinearProgressIndicator(
                value: _loadingProgress > 0 ? _loadingProgress : null,
                minHeight: 3,
                backgroundColor: Colors.transparent,
                color: Colors.orangeAccent,
              ),
            ),

          // Loading pill
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            bottom: 24, left: 0, right: _panelOpen ? 280 : 0,
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

          // Zoom buttons
          Positioned(
            bottom: 80, left: 16,
            child: Column(
              children: [
                _buildZoomButton(Icons.add, () async {
                  final cam = _mapController?.cameraPosition;
                  if (cam == null) return;
                  await _mapController?.animateCamera(
                    CameraUpdate.newCameraPosition(
                      CameraPosition(target: cam.target, zoom: (cam.zoom + 1).clamp(1, 20)),
                    ),
                  );
                }),
                const SizedBox(height: 4),
                _buildZoomButton(Icons.remove, () async {
                  final cam = _mapController?.cameraPosition;
                  if (cam == null) return;
                  await _mapController?.animateCamera(
                    CameraUpdate.newCameraPosition(
                      CameraPosition(target: cam.target, zoom: (cam.zoom - 1).clamp(1, 20)),
                    ),
                  );
                }),
              ],
            ),
          ),

          // Error banner
          if (_errorMessage != null)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              bottom: 80, left: 16, right: _panelOpen ? 296 : 16,
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

          // Right-side panel (slides in/out)
          Positioned(
            top: 0, right: 0, bottom: 0, width: 280,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _setMapCanvasInteractive(false),
              onPointerUp:   (_) => _setMapCanvasInteractive(true),
              onPointerCancel: (_) => _setMapCanvasInteractive(true),
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                offset: _panelOpen ? Offset.zero : const Offset(1.0, 0),
                child: _buildPanel(),
              ),
            ),
          ),

          // Panel toggle tab
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            top: 0,
            bottom: 0,
            right: _panelOpen ? 280 : 0,
            width: 36,
            child: Align(
              alignment: Alignment.center,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => _panelOpen = !_panelOpen),
                  child: Container(
                    width: 36, height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(8)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 6,
                          offset: const Offset(-2, 0),
                        ),
                      ],
                    ),
                    child: Icon(
                      _panelOpen ? Icons.chevron_right : Icons.chevron_left,
                      size: 20, color: Colors.grey.shade600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildZoomButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: SizedBox(
          width: 36, height: 36,
          child: Icon(icon, size: 20, color: Colors.black87),
        ),
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
            color: Colors.white.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
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
        color: Colors.white.withValues(alpha: 0.95),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(-4, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          controller: _panelScroll,
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
              _buildFindSunnySpotsSection(),
              const Divider(height: 28),
              if (_clickedPoint != null)
                _buildPointInfoCard()
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.touch_app_outlined, size: 15, color: Colors.grey.shade400),
                      const SizedBox(width: 6),
                      Text('Tap the map to inspect a point',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                    ],
                  ),
                ),
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
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.orange,
            inactiveTrackColor: Colors.orange.shade100,
            thumbColor: Colors.white,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            overlayColor: Colors.orange.withValues(alpha: 0.2),
          ),
          child: Slider(
            value: _hour,
            min: 0, max: 23, divisions: 23,
            onChangeStart: (_) {
              setState(() => _draggingSlider = true);
              _setMapPointerEvents(false);
            },
            onChanged:   (v) => setState(() => _hour = v),
            onChangeEnd: (_) {
              setState(() => _draggingSlider = false);
              _setMapPointerEvents(true);
              fetchShadows();
            },
          ),
        ),
        // Day/night strip with sunrise/sunset markers
        if (_sunriseHour != null && _sunsetHour != null)
          _buildDayNightStrip(_sunriseHour!, _sunsetHour!),
        // Hour labels
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, top: 2),
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

  /// Thin coloured bar + tick marks showing day (amber) vs night (grey).
  /// Flutter's Slider track starts/ends at 12 px from the widget edge (overlay radius).
  Widget _buildDayNightStrip(double sr, double ss) {
    const sliderPad = 12.0;
    const nightClr  = Color(0xFFCFD8DC); // blue-grey 100
    const dayClr    = Color(0xFFFFE082); // amber 200

    return LayoutBuilder(
      builder: (context, constraints) {
        final total   = constraints.maxWidth;
        final trackW  = total - sliderPad * 2;
        final srFrac  = (sr / 23.0).clamp(0.0, 1.0);
        final ssFrac  = (ss / 23.0).clamp(0.0, 1.0);
        final srX     = sliderPad + srFrac * trackW;
        final ssX     = sliderPad + ssFrac * trackW;

        // Clamp label positions so they don't overflow the widget
        final srLabelX = (srX - 14).clamp(0.0, total - 36);
        final ssLabelX = (ssX - 14).clamp(0.0, total - 36);

        return SizedBox(
          height: 20,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // ── coloured strip ──
              Positioned(
                left: sliderPad, right: sliderPad, top: 4,
                child: SizedBox(
                  height: 4,
                  child: Row(
                    children: [
                      Flexible(
                        flex: (srFrac * 1000).round().clamp(1, 999),
                        child: Container(color: nightClr),
                      ),
                      Flexible(
                        flex: ((ssFrac - srFrac) * 1000).round().clamp(1, 999),
                        child: Container(color: dayClr),
                      ),
                      Flexible(
                        flex: ((1 - ssFrac) * 1000).round().clamp(1, 999),
                        child: Container(color: nightClr),
                      ),
                    ],
                  ),
                ),
              ),
              // ── sunrise tick ──
              Positioned(
                left: srX - 0.5, top: 0,
                child: Container(width: 1, height: 12,
                    color: Colors.orange.shade400),
              ),
              // ── sunset tick ──
              Positioned(
                left: ssX - 0.5, top: 0,
                child: Container(width: 1, height: 12,
                    color: Colors.blueGrey.shade300),
              ),
              // ── sunrise label ──
              Positioned(
                left: srLabelX, top: 12,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wb_sunny_outlined, size: 8,
                        color: Colors.orange.shade500),
                    const SizedBox(width: 1),
                    Text(_formatSliderHour(sr),
                        style: TextStyle(
                            fontSize: 8,
                            color: Colors.orange.shade700,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              // ── sunset label ──
              Positioned(
                left: ssLabelX, top: 12,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.nightlight_round, size: 8,
                        color: Colors.blueGrey.shade400),
                    const SizedBox(width: 1),
                    Text(_formatSliderHour(ss),
                        style: TextStyle(
                            fontSize: 8,
                            color: Colors.blueGrey.shade500,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatSliderHour(double hour) {
    final h = hour.toInt().clamp(0, 23);
    final m = ((hour - h) * 60).round();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
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
          children: [
            ...[1, 2, 4].map<Widget>((speed) {
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
          }),
            // LIVE button
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _toggleLiveMode,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _liveMode ? Colors.red.shade400 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_liveMode)
                        Container(
                          width: 6, height: 6,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      Text(
                        'LIVE',
                        style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700,
                          color: _liveMode ? Colors.white : Colors.black54,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---- Point info popup ----
  Widget _buildPointInfoCard() {
    final info = _pointInfo;
    final inShadow = info == null ? true : (info['in_shadow'] as bool? ?? true);
    final sunCount = info == null ? 0 : (info['sun_hours_count'] as int? ?? 0);
    final periods  = info == null ? <dynamic>[] : (info['sun_periods'] as List<dynamic>? ?? []);

    String fmt(int h) => '${h.toString().padLeft(2, '0')}:00';

    final statusColor = inShadow ? const Color(0xFF2d4862) : const Color(0xFFFF8C00);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          // Header row — same style as other section headers
          Row(
            children: [
              Icon(
                inShadow ? Icons.nights_stay_outlined : Icons.wb_sunny,
                color: statusColor, size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                _pointInfoLoading
                    ? 'Checking…'
                    : inShadow ? 'In Shadow' : 'In Sun',
                style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  color: statusColor, letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    _ignoreNextMapClick = true;
                    _hidePin();
                    setState(() {
                      _clickedPoint = null;
                      _pointInfo    = null;
                    });
                  },
                  child: Icon(Icons.close, color: Colors.grey.shade400, size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_pointInfoLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange)),
              ),
            )
          else ...[
            Row(
              children: [
                const Icon(Icons.wb_sunny_outlined, size: 14, color: Colors.orange),
                const SizedBox(width: 6),
                Text(
                  sunCount == 0
                      ? 'No direct sun today'
                      : '$sunCount hour${sunCount == 1 ? '' : 's'} of direct sun today',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (periods.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6, runSpacing: 4,
                children: periods.map((p) {
                  final from = p['from'] as int;
                  final to   = p['to']   as int;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Text(
                      '${fmt(from)} – ${fmt(to)}',
                      style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                    ),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '${_clickedPoint!.latitude.toStringAsFixed(5)}°, '
              '${_clickedPoint!.longitude.toStringAsFixed(5)}°',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
            ),
          ],
        ],
      );
  }

  // ---- Haversine distance helper ----
  double _distanceMeters(LatLng a, LatLng b) {
    const r = 6371000.0;
    final lat1 = a.latitude  * pi / 180;
    final lat2 = b.latitude  * pi / 180;
    final dlat = (b.latitude  - a.latitude)  * pi / 180;
    final dlon = (b.longitude - a.longitude) * pi / 180;
    final x = sin(dlat / 2) * sin(dlat / 2) +
        cos(lat1) * cos(lat2) * sin(dlon / 2) * sin(dlon / 2);
    return r * 2 * atan2(sqrt(x), sqrt(1 - x));
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  // ---- Find sunny spots ----
  Widget _buildFindSunnySpotsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _findingSunnySpots ? null : _findSunnySpots,
                icon: _findingSunnySpots
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.wb_sunny, size: 16),
                label: Text(_findingSunnySpots ? 'Searching...' : 'Find sunny spots'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.orange.shade200,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            if (_sunnySpots.isNotEmpty) ...[
              const SizedBox(width: 8),
              IconButton(
                onPressed: _clearSunnySpots,
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Clear spots',
                style: IconButton.styleFrom(
                  backgroundColor: Colors.grey.shade100,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                padding: const EdgeInsets.all(10),
              ),
            ],
          ],
        ),
        if (_sunnySpots.isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._sunnySpots.asMap().entries.map((e) {
            final idx          = e.key;
            final spot         = e.value;
            final spotPos      = LatLng(spot['lat'] as double, spot['lon'] as double);
            final sunHoursLeft = spot['sun_hours_left'] as int;
            final sunUntil     = spot['sun_until'] as int?;

            // Distance from GPS fix (if available)
            final gps = _gpsPosition;
            final distLabel = gps != null
                ? _formatDistance(_distanceMeters(gps, spotPos))
                : null;

            // "Sun until HH:00" label
            final sunUntilLabel = sunUntil != null
                ? 'until ${sunUntil.toString().padLeft(2, '0')}:00'
                : null;

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    _mapController?.animateCamera(
                      CameraUpdate.newLatLngZoom(spotPos, 17.5),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 22, height: 22,
                          decoration: const BoxDecoration(
                            color: Color(0xFFFFD700),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              '${idx + 1}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Sunny spot ${idx + 1}',
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  if (distLabel != null) ...[
                                    Icon(Icons.directions_walk, size: 11,
                                        color: Colors.grey.shade500),
                                    const SizedBox(width: 2),
                                    Text(distLabel,
                                        style: TextStyle(
                                            fontSize: 11, color: Colors.grey.shade600)),
                                    const SizedBox(width: 8),
                                  ],
                                  Icon(Icons.wb_sunny_outlined, size: 11,
                                      color: Colors.orange.shade400),
                                  const SizedBox(width: 2),
                                  Text(
                                    sunUntilLabel != null
                                        ? '$sunHoursLeft h · $sunUntilLabel'
                                        : '$sunHoursLeft h left',
                                    style: TextStyle(
                                        fontSize: 11, color: Colors.orange.shade700),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right, size: 16, color: Colors.orange.shade300),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
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

}
