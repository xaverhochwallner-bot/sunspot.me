import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  // Auto-detects the Flask server from the page's host (same machine, port 5000).
  // Override with ?server=https://your-tunnel-url for Cloudflare/ngrok tunnels.
  static String get flaskBaseUrl {
    final uri = Uri.base;
    final override = uri.queryParameters['server'];
    if (override != null && override.isNotEmpty) {
      return override.replaceAll(RegExp(r'/$'), '');
    }
    return '${uri.scheme}://${uri.host}:5000';
  }
  static const String mapStyle     = 'https://tiles.openfreemap.org/styles/bright';

  MapLibreMapController? _mapController;
  LatLng _currentCenter = const LatLng(48.2082, 16.3738);
  LatLng? _lastSearchCenter;
  double? _lastSearchZoom;
  bool    _suppressResultClear = false;
  Timer? _debounceTimer;

  double   _hour          = DateTime.now().toUtc().add(const Duration(hours: 1)).hour.toDouble(); // Vienna CET fallback
  DateTime _selectedDate  = DateTime.now();
  double   _elevation     = 0.0;
  double   _azimuth       = 0.0;
  bool     _loading       = false;
  bool     _mapReady      = false;
  bool     _animating      = false;
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

  // Client-side shadow result cache: key = 'zoom_hour_month_day_lat3_lon3'
  final Map<String, Map<String, dynamic>> _shadowResultCache = {};
  static const int _shadowCacheMax = 30;

  // Panel
  bool _panelOpen = true;
  bool _panelExpanded = false;

  // Live mode
  bool   _liveMode  = false;
  Timer? _liveTimer;
  int    _animSpeed = 1; // 1×=600ms, 2×=300ms, 4×=100ms per hour step

  // Sunrise / sunset (local hours, e.g. 6.0, 20.0)
  double? _sunriseHour;
  double? _sunsetHour;

  // Point info popup
  LatLng?                _clickedPoint;
  bool                   _pointInfoLoading = false;
  Map<String, dynamic>?  _pointInfo;
  bool                   _ignoreNextMapClick = false;
  VoidCallback?          _refreshPointSheet;
  bool                   _pinLayerReady = false;
  double                 _screenWidth = 1200;

  // GPS blue dot
  LatLng? _gpsPosition;
  bool    _myLocationLayerReady = false;

  // Sunny spots
  List<Map<String, dynamic>> _sunnySpots          = [];
  bool                       _sunnySpotsLayerReady = false;
  bool                       _findingSunnySpots    = false;
  bool                       _spotsNoResults       = false;
  bool                       _poisNoResults        = false;
  List<Offset>               _sunnySpotScreenPos   = [];
  List<Offset>               _tourMarkerScreenPos  = [];
  List<Offset>               _poiScreenPos         = [];

  // Places (POI) mode
  bool                       _placesMode        = false;
  List<Map<String, dynamic>> _sunnyPois         = [];
  bool                       _loadingPois       = false;
  bool                       _poiMarkersReady   = false;


  bool                       _spotsZoomHint     = false;

  // Weather overlay
  Map<String, dynamic>? _weatherData;

  // Heatmap layer
  bool _heatmapMode        = false;
  bool _heatmapLoading     = false;
  bool _heatmapLayerReady  = false;

  // Reverse-geocoded addresses — keyed by "lat,lon"
  Map<String, String> _spotAddresses = {};

  // Saved spots — persisted to localStorage
  List<Map<String, dynamic>> _savedSpots = [];

  // Sunny Tour
  int                        _tourDuration    = 30;   // minutes
  List<Map<String, dynamic>> _tourSpots       = [];
  bool                       _tourBuilding    = false;
  bool                       _tourLayerReady  = false;
  double?                    _pendingTourLat;
  double?                    _pendingTourLon;

  // Saved spots sunny status  key = 'lat,lon', null=loading, true=sunny, false=shadow
  Map<String, bool?> _savedSunny = {};

  // Inline spot detail (replaces modal)
  Map<String, dynamic>? _selectedSpot;
  int _selectedSpotIdx = 0;
  LatLng? _detailReturnCenter;
  double? _detailReturnZoom;

  // Panel scroll
  final ScrollController _panelScroll = ScrollController();

  // Mobile bottom UI
  int _mobileTab = 0;
  final ScrollController _mobileContentScroll = ScrollController();
  double _screenHeight = 800.0;

  bool get _isMobile => _screenWidth < 650;

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

  // Vienna local time — handles CET (UTC+1) / CEST (UTC+2) without a package.
  DateTime _viennaNow() {
    final utc = DateTime.now().toUtc();
    final isDst = _isViennaDst(utc);
    return utc.add(Duration(hours: isDst ? 2 : 1));
  }

  bool _isViennaDst(DateTime utc) {
    if (utc.month > 3 && utc.month < 10) return true;
    if (utc.month < 3 || utc.month > 10) return false;
    final lastSun = _lastSundayOf(utc.year, utc.month);
    return utc.month == 3 ? utc.day >= lastSun : utc.day < lastSun;
  }

  int _lastSundayOf(int year, int month) {
    var d = DateTime.utc(year, month + 1, 0); // last day of month
    while (d.weekday != DateTime.sunday) d = d.subtract(const Duration(days: 1));
    return d.day;
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
    _heatmapLayerReady    = false;
    _tourLayerReady       = false;
    _poiMarkersReady      = false;
    _injectAttributionCss();
    _loadSaved();
    Future.delayed(const Duration(milliseconds: 500), _refreshSavedSunny);

    // Handle shared tour link: ?tour_lat=...&tour_lon=...&tour_duration=...
    final params = Uri.base.queryParameters;
    final tLat = double.tryParse(params['tour_lat'] ?? '');
    final tLon = double.tryParse(params['tour_lon'] ?? '');
    if (tLat != null && tLon != null) {
      final dur = int.tryParse(params['tour_duration'] ?? '') ?? _tourDuration;
      _currentCenter = LatLng(tLat, tLon);
      _tourDuration  = dur;
      _pendingTourLat = tLat;
      _pendingTourLon = tLon;
      await _mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(_currentCenter, 15.0));
      if (_isMobile) setState(() => _mobileTab = 2);
      await Future.delayed(const Duration(milliseconds: 800));
      _buildTour();
    }

    fetchShadows();
    _initGpsOnStart();
    _fetchWeather(_currentCenter.latitude, _currentCenter.longitude);
  }

  void _injectAttributionCss() {
    final style = html.StyleElement();
    style.text =
        // Hide attribution and logo entirely
        '.maplibregl-ctrl-attrib { display: none !important; }'
        '.maplibregl-ctrl-logo { display: none !important; }'
        '.maplibregl-ctrl-bottom-right { display: none !important; }';
    html.document.head!.append(style);
  }

  void _onCameraIdle() {
    if (_mapController == null) return;
    final pos    = _mapController!.cameraPosition;
    final center = pos?.target;
    if (center == null) return;
    _currentCenter = center;

    final zoom = pos?.zoom ?? 0;
    if (_suppressResultClear) {
      _lastSearchCenter = center;
      _lastSearchZoom   = zoom;
      _suppressResultClear = false;
    }

    if (_sunnySpots.isNotEmpty) _refreshSunnySpotPositions();
    if (_tourSpots.isNotEmpty) _refreshTourMarkerPositions();
    if (_sunnyPois.isNotEmpty) _refreshPoiPositions();
    _debounceTimer?.cancel();
    if (_heatmapMode) {
      _debounceTimer = Timer(const Duration(milliseconds: 600), () {
        setState(() => _heatmapLoading = true);
        _fetchAndShowHeatmap().then((_) {
          if (mounted) setState(() => _heatmapLoading = false);
        });
      });
    } else {
      _debounceTimer = Timer(const Duration(milliseconds: 600), fetchShadows);
    }
  }

  void _onMapClick(Point<double> point, LatLng coordinates) {
    if (_ignoreNextMapClick) {
      _ignoreNextMapClick = false;
      return;
    }
    // Reject clicks in the sidebar zone (desktop only)
    if (!_isMobile && point.x > _screenWidth - 280) return;
    if (_searchResults.isNotEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    // Point inspection only active on Saved tab
    if (_mobileTab != 3) return;
    setState(() {
      _clickedPoint      = coordinates;
      _pointInfo         = null;
      _pointInfoLoading  = true;
    });
    _showPin(coordinates);
    _fetchPointInfo(coordinates);
    _showPointSheet(coordinates);
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
        _refreshPointSheet?.call();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _pointInfoLoading = false);
        _refreshPointSheet?.call();
      }
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

    final zoom = ctrl.cameraPosition?.zoom ?? 0;
    if (zoom < 13) {
      setState(() { _spotsZoomHint = true; _sunnySpots = []; });
      _clearSunnySpots();
      return;
    }

    setState(() { _findingSunnySpots = true; _spotsZoomHint = false; _spotsNoResults = false; });
    _lastSearchCenter = ctrl.cameraPosition?.target;
    _lastSearchZoom   = ctrl.cameraPosition?.zoom;
    await _clearTourLine();
    try {
      final bounds = await ctrl.getVisibleRegion();
      final zoom   = ctrl.cameraPosition?.zoom ?? 15.0;
      final h      = _hour.toInt();
      final min    = ((_hour * 60).toInt() % 60);
      final date   = _selectedDate;

      final dateStr = '${date.year}-${date.month.toString().padLeft(2,'0')}-${date.day.toString().padLeft(2,'0')}';
      final vpParams =
          '&minLat=${bounds.southwest.latitude}&minLon=${bounds.southwest.longitude}'
          '&maxLat=${bounds.northeast.latitude}&maxLon=${bounds.northeast.longitude}'
          '&zoom=${zoom.round()}';
      final centerParams =
          '?lat=${_currentCenter.latitude}&lon=${_currentCenter.longitude}';

      // Run grid spots + parks + squares in parallel
      final spotsUri  = Uri.parse('$flaskBaseUrl/find_sunny_spots$centerParams'
          '&hour=$h&minute=$min&month=${date.month}&day=${date.day}'
          '&zoom=${zoom.round()}$vpParams&n=3');
      final parksUri  = Uri.parse('$flaskBaseUrl/sunny_pois$centerParams$vpParams'
          '&hour=$h&minute=$min&date=$dateStr&types=park');
      final squaresUri = Uri.parse('$flaskBaseUrl/sunny_pois$centerParams$vpParams'
          '&hour=$h&minute=$min&date=$dateStr&types=square');

      final results = await Future.wait([
        http.get(spotsUri).timeout(const Duration(seconds: 30)),
        http.get(parksUri).timeout(const Duration(seconds: 30)),
        http.get(squaresUri).timeout(const Duration(seconds: 30)),
      ]);

      List<Map<String, dynamic>> parsePois(http.Response resp, String category) {
        try {
          final d = jsonDecode(resp.body) as Map<String, dynamic>;
          if (d['reason'] == 'zoom_in') return [];
          return (d['spots'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>().map((p) => <String, dynamic>{
            'lat': (p['lat'] as num).toDouble(),
            'lon': (p['lon'] as num).toDouble(),
            'sun_hours_left': p['sun_hours'] as int? ?? (p['sun_hours_left'] as int? ?? 0),
            'sun_until': p['sun_until'] as int?,
            '_poi_name': p['name'] as String? ?? '',
            '_poi_amenity': p['amenity'] as String? ?? '',
            '_category': category,
          }).take(3).toList();
        } catch (_) { return []; }
      }

      final gridData   = jsonDecode(results[0].body) as Map<String, dynamic>;
      final gridReason = gridData['reason'] as String? ?? '';

      if (gridReason == 'night') {
        setState(() { _sunnySpots = []; _spotsZoomHint = false; });
        _showError('No sun at this hour — move the time slider');
        return;
      }

      final gridSpots = (gridData['spots'] as List<dynamic>? ?? []).map((s) => <String, dynamic>{
        'lat':            (s['lat']  as num).toDouble(),
        'lon':            (s['lon']  as num).toDouble(),
        'sun_hours_left': (s['sun_hours_left'] as num?)?.toInt() ?? 0,
        'sun_until':      s['sun_until'] as int?,
        '_category':      'spot',
      }).take(3).toList();

      final parks   = parsePois(results[1], 'park');
      final squares = parsePois(results[2], 'square');

      // Merge all, sort by sun hours desc, cap at 8
      final merged = [...gridSpots, ...parks, ...squares];
      final zoomIn = merged.isEmpty && gridReason == 'zoom_in';
      setState(() => _spotsZoomHint = zoomIn);
      merged.sort((a, b) => ((b['sun_hours_left'] as int?) ?? 0)
          .compareTo((a['sun_hours_left'] as int?) ?? 0));
      final allSpots = merged.take(8).toList();

      setState(() { _sunnySpots = allSpots; _spotsNoResults = allSpots.isEmpty && !zoomIn; });
      _geocodeSpots(allSpots);
      await _showSunnySpotMarkers(allSpots);
      await _refreshSunnySpotPositions();

      if (allSpots.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 150));
        if (_isMobile) {
          setState(() => _mobileTab = 1);
        } else if (_panelScroll.hasClients) {
          _panelScroll.animateTo(
            _panelScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
          );
        }
      }
    } on TimeoutException {
      if (mounted) _showError('Search timed out — try zooming in closer');
    } catch (_) {
      if (mounted) _showError('Could not find sunny spots');
    } finally {
      if (mounted) setState(() => _findingSunnySpots = false);
    }
  }

  Future<void> _showSunnySpotMarkers(List<Map<String, dynamic>> spots) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    final features = spots.asMap().entries.map((e) {
      final s = e.value;
      final currentlySunny = (s['sun_until'] != null) ? 1 : 0;
      return {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [s['lon'], s['lat']]},
        'properties': {'index': e.key + 1, 'currently_sunny': currentlySunny},
      };
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
          circleColor: ['case', ['==', ['get', 'currently_sunny'], 1], '#FFD700', '#999999'],
          circleOpacity: 0.2,
          circleStrokeWidth: 0,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'sunny-spots', 'sunny-spots-dot',
        CircleLayerProperties(
          circleRadius: 8,
          circleColor: ['case', ['==', ['get', 'currently_sunny'], 1], '#FFD700', '#AAAAAA'],
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
    setState(() { _sunnySpots = []; _sunnySpotScreenPos = []; });
    if (!_sunnySpotsLayerReady) return;
    await _mapController?.setGeoJsonSource(
        'sunny-spots', {'type': 'FeatureCollection', 'features': []});
  }

  Future<void> _findSunnyPois() async {
    final ctrl = _mapController;
    if (ctrl == null || !_mapReady) return;

    final zoom = ctrl.cameraPosition?.zoom ?? 0;
    if (zoom < 13) {
      setState(() => _sunnyPois = []);
      _clearPoiMarkers();
      _showError('Zoom in to see places');
      return;
    }

    _lastSearchCenter = ctrl.cameraPosition?.target;
    _lastSearchZoom   = ctrl.cameraPosition?.zoom;
    setState(() { _loadingPois = true; _sunnyPois = []; _poiScreenPos = []; _poisNoResults = false; });
    try {
      final bounds  = await ctrl.getVisibleRegion();
      final d       = _selectedDate;
      final dateStr = '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
      final h       = _hour.toInt();
      final min     = ((_hour * 60).toInt() % 60);
      final types   = 'terrace';
      final zoom    = ctrl.cameraPosition?.zoom ?? 15.0;
      final uri = Uri.parse(
        '$flaskBaseUrl/sunny_pois'
        '?lat=${_currentCenter.latitude}&lon=${_currentCenter.longitude}'
        '&minLat=${bounds.southwest.latitude}&minLon=${bounds.southwest.longitude}'
        '&maxLat=${bounds.northeast.latitude}&maxLon=${bounds.northeast.longitude}'
        '&hour=$h&minute=$min&date=$dateStr&types=$types'
        '&zoom=${zoom.round()}',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 20));
      if (mounted && resp.statusCode == 200) {
        final data   = jsonDecode(resp.body) as Map<String, dynamic>;
        final reason = data['reason'] as String? ?? '';
        if (reason == 'night') {
          _showError('No sun at this hour — move the time slider');
          return;
        }
        final list = data['spots'] as List<dynamic>? ?? [];
        final pois = list.cast<Map<String, dynamic>>();
        setState(() { _sunnyPois = pois; _poisNoResults = pois.isEmpty; });
        await _showPoiMarkers(pois);
        await _refreshPoiPositions();
      } else if (mounted) {
        _showError('Server error ${resp.statusCode}');
      }
    } on TimeoutException {
      if (mounted) _showError('Search timed out — try zooming in closer');
    } catch (e) {
      if (mounted) _showError('Could not load places');
    } finally {
      if (mounted) setState(() => _loadingPois = false);
    }
  }

  Future<void> _showPoiMarkers(List<Map<String, dynamic>> pois) async {
    final ctrl = _mapController;
    if (ctrl == null) return;
    final features = pois.asMap().entries.map((e) {
      final p = e.value;
      final currentlySunny = (p['sun_until'] != null) ? 1 : 0;
      return {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [p['lon'], p['lat']]},
        'properties': {'index': e.key + 1, 'currently_sunny': currentlySunny},
      };
    }).toList();
    final geoJson = {'type': 'FeatureCollection', 'features': features};
    if (_poiMarkersReady) {
      await ctrl.setGeoJsonSource('poi-markers', geoJson);
    } else {
      await ctrl.addSource('poi-markers', GeojsonSourceProperties(data: geoJson));
      await ctrl.addLayer('poi-markers', 'poi-marker-glow',
        CircleLayerProperties(
          circleRadius: 20,
          circleColor: ['case', ['==', ['get', 'currently_sunny'], 1], '#FF8C00', '#999999'],
          circleOpacity: 0.2, circleStrokeWidth: 0),
        enableInteraction: false,
      );
      await ctrl.addLayer('poi-markers', 'poi-marker-dot',
        CircleLayerProperties(
          circleRadius: 9,
          circleColor: ['case', ['==', ['get', 'currently_sunny'], 1], '#FF8C00', '#AAAAAA'],
          circleOpacity: 1.0, circleStrokeWidth: 2, circleStrokeColor: '#FFFFFF'),
        enableInteraction: false,
      );
      _poiMarkersReady = true;
    }
  }

  Future<void> _clearPoiMarkers() async {
    if (mounted) setState(() => _poiScreenPos = []);
    if (!_poiMarkersReady) return;
    await _mapController?.setGeoJsonSource(
        'poi-markers', {'type': 'FeatureCollection', 'features': []});
  }

  Future<void> _refreshSunnySpotPositions() async {
    final ctrl = _mapController;
    if (ctrl == null || _sunnySpots.isEmpty) return;
    final pts = await Future.wait(
      _sunnySpots.map((s) => ctrl.toScreenLocation(LatLng(s['lat'] as double, s['lon'] as double))),
    );
    if (mounted) setState(() {
      _sunnySpotScreenPos = pts.map((p) => Offset(p.x.toDouble(), p.y.toDouble())).toList();
    });
  }

  Future<void> _refreshTourMarkerPositions() async {
    final ctrl = _mapController;
    if (ctrl == null || _tourSpots.isEmpty) return;
    final pts = await Future.wait(
      _tourSpots.map((s) => ctrl.toScreenLocation(LatLng(s['lat'] as double, s['lon'] as double))),
    );
    if (mounted) setState(() {
      _tourMarkerScreenPos = pts.map((p) => Offset(p.x.toDouble(), p.y.toDouble())).toList();
    });
  }

  Future<void> _refreshPoiPositions() async {
    final ctrl = _mapController;
    if (ctrl == null || _sunnyPois.isEmpty) return;
    final pts = await Future.wait(
      _sunnyPois.map((s) => ctrl.toScreenLocation(LatLng(s['lat'] as double, s['lon'] as double))),
    );
    if (mounted) setState(() {
      _poiScreenPos = pts.map((p) => Offset(p.x.toDouble(), p.y.toDouble())).toList();
    });
  }

  // -------------------------------------------------------------------------
  // Saved spots — localStorage persistence
  // -------------------------------------------------------------------------

  void _loadSaved() {
    try {
      final raw = html.window.localStorage['sunspot_saved'];
      if (raw != null) {
        setState(() {
          _savedSpots = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        });
      }
    } catch (_) {}
  }

  void _persistSaved() {
    html.window.localStorage['sunspot_saved'] = jsonEncode(_savedSpots);
  }

  Future<void> _refreshSavedSunny() async {
    if (_savedSpots.isEmpty) return;
    final d   = _selectedDate;
    final h   = _hour.toInt();
    final min = ((_hour * 60).toInt() % 60);
    final dateStr = '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
    for (final s in _savedSpots) {
      final lat = s['lat'] as double;
      final lon = s['lon'] as double;
      final key = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
      if (mounted) setState(() => _savedSunny[key] = null);
      try {
        final uri = Uri.parse('$flaskBaseUrl/is_sunny'
            '?lat=$lat&lon=$lon&date=$dateStr&hour=$h&minute=$min');
        final res = await http.get(uri);
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (mounted) setState(() => _savedSunny[key] = data['sunny'] as bool?);
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------------
  // Weather (Open-Meteo, no API key)
  // -------------------------------------------------------------------------

  Future<void> _fetchWeather(double lat, double lon) async {
    try {
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$lat&longitude=$lon'
        '&current=temperature_2m,weather_code,uv_index'
        '&timezone=auto',
      );
      final res = await http.get(uri);
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _weatherData = data['current'] as Map<String, dynamic>?);
      }
    } catch (_) {}
  }

  String _weatherEmoji(int code) {
    if (code == 0)           return '☀️';
    if (code <= 3)           return '⛅';
    if (code <= 48)          return '🌫️';
    if (code <= 67)          return '🌧️';
    if (code <= 77)          return '❄️';
    if (code <= 82)          return '🌦️';
    return                          '⛈️';
  }

  Color _uvColor(num uv) {
    if (uv <= 2)  return Colors.green;
    if (uv <= 5)  return Colors.yellow.shade700;
    if (uv <= 7)  return Colors.orange;
    if (uv <= 10) return Colors.red;
    return                Colors.purple;
  }

  Widget _buildWeatherWidget() {
    final data = _weatherData;
    if (data == null) return const SizedBox.shrink();
    final temp    = (data['temperature_2m'] as num?)?.round() ?? 0;
    final code    = (data['weather_code']   as num?)?.toInt() ?? 0;
    final uv      = (data['uv_index']       as num?) ?? 0;
    final uvInt   = uv.round();
    final emoji   = _weatherEmoji(code);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 5),
          Text('$temp°',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('UV $uvInt',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                  color: Colors.grey.shade700)),
          const SizedBox(width: 3),
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: _uvColor(uv),
              shape: BoxShape.circle,
            ),
          ),
          if (_elevation > 0) ...[
            const SizedBox(width: 8),
            Transform.rotate(
              angle: (_azimuth - 180) * 3.14159265 / 180,
              child: Icon(Icons.navigation, size: 13, color: Colors.orange.shade400),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Heatmap layer
  // -------------------------------------------------------------------------

  Future<void> _setShadowLayersVisible(bool visible) async {
    if (!_shadowLayersReady) return;
    await _mapController?.setLayerProperties(
        'shadow-l0-fill', FillLayerProperties(fillOpacity: visible ? 0.3 : 0.0));
    await _mapController?.setLayerProperties(
        'shadow-l1-fill', FillLayerProperties(fillOpacity: visible ? 0.2 : 0.0));
    await _mapController?.setLayerProperties(
        'shadow-l2-fill', FillLayerProperties(fillOpacity: visible ? 0.1 : 0.0));
    // Trigger a full shadow refresh when re-enabling so correct opacities are restored
    if (visible) fetchShadows();
  }

  Future<void> _toggleHeatmap() async {
    if (_heatmapLoading) return;
    if (_heatmapMode) {
      // Switch back to shadow
      setState(() => _heatmapMode = false);
      await _clearHeatmapLayers();
      await _setShadowLayersVisible(true);
    } else {
      // Switch to heatmap
      await _setShadowLayersVisible(false);
      setState(() { _heatmapMode = true; _heatmapLoading = true; });
      await _fetchAndShowHeatmap();
      setState(() => _heatmapLoading = false);
    }
  }

  Future<void> _fetchAndShowHeatmap() async {
    final ctrl = _mapController;
    if (ctrl == null) return;
    try {
      final bounds = await ctrl.getVisibleRegion();
      final zoom   = (ctrl.cameraPosition?.zoom ?? 12.0).clamp(1.0, 13.0);
      final date   = _selectedDate;
      final h      = _hour.toInt();
      final min    = ((_hour * 60).toInt() % 60);
      final uri    = Uri.parse(
        '$flaskBaseUrl/heatmap'
        '?minLat=${bounds.southwest.latitude}'
        '&minLon=${bounds.southwest.longitude}'
        '&maxLat=${bounds.northeast.latitude}'
        '&maxLon=${bounds.northeast.longitude}'
        '&month=${date.month}&day=${date.day}'
        '&hour=$h&minute=$min'
        '&zoom=${zoom.round()}',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 90));
      if (res.statusCode != 200 || !mounted || !_heatmapMode) return;
      final geojson = jsonDecode(res.body) as Map<String, dynamic>;
      await _showHeatmapLayers(geojson);
    } catch (e) {
      if (mounted) {
        _showError('Sun Map error: ${e.toString().split('\n').first}');
        setState(() => _heatmapMode = false);
      }
    }
  }

  Future<void> _showHeatmapLayers(Map<String, dynamic> geojson) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    if (!_heatmapLayerReady) {
      await ctrl.addGeoJsonSource('sunmap-src', geojson);
      await ctrl.addFillLayer(
        'sunmap-src', 'sunmap-fill',
        FillLayerProperties(fillColor: '#FFD700', fillOpacity: 0.50),
      );
      _heatmapLayerReady = true;
    } else {
      await ctrl.setGeoJsonSource('sunmap-src', geojson);
    }
  }

  Future<void> _clearHeatmapLayers() async {
    if (!_heatmapLayerReady) return;
    final empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};
    await _mapController?.setGeoJsonSource('sunmap-src', empty);
  }

  // -------------------------------------------------------------------------
  // Reverse geocoding (Nominatim)
  // -------------------------------------------------------------------------

  Future<void> _geocodeSpots(List<Map<String, dynamic>> spots) async {
    for (final spot in spots) {
      // Skip POI add-ons — they already have a name from OSM
      if ((spot['_poi_name'] as String? ?? '').isNotEmpty) continue;
      final lat = spot['lat'] as double;
      final lon = spot['lon'] as double;
      await _reverseGeocode(lat, lon);
      await Future.delayed(const Duration(milliseconds: 300)); // respect Nominatim rate limit
    }
  }

  Future<String> _reverseGeocode(double lat, double lon) async {
    final key = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
    if (_spotAddresses.containsKey(key)) return _spotAddresses[key]!;
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json',
      );
      final res = await http.get(uri, headers: {'User-Agent': 'Sunspot.me/1.0'});
      if (res.statusCode != 200) return '';
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final addr = data['address'] as Map<String, dynamic>?;
      String label = '';
      if (addr != null) {
        final road = (addr['road'] ?? addr['pedestrian'] ?? addr['path'] ?? '') as String;
        final num  = (addr['house_number'] ?? '') as String;
        label = num.isNotEmpty ? '$road $num' : road;
      }
      if (label.isEmpty) {
        label = ((data['display_name'] as String?) ?? '').split(',').first.trim();
      }
      if (mounted) setState(() => _spotAddresses[key] = label);
      return label;
    } catch (_) {
      return '';
    }
  }

  // -------------------------------------------------------------------------
  // Spot popup
  // -------------------------------------------------------------------------

  void _selectSpot(Map<String, dynamic> spot, int idx) {
    _detailReturnCenter = _lastSearchCenter ?? _currentCenter;
    _detailReturnZoom   = _lastSearchZoom ?? _mapController?.cameraPosition?.zoom ?? 14.0;
    final lat = spot['lat'] as double;
    final lon = spot['lon'] as double;
    if (_panelExpanded) setState(() => _panelExpanded = false);
    _suppressResultClear = true;
    _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(lat, lon), 15.5));
    final key          = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
    final poiName      = spot['_poi_name'] as String? ?? '';
    final address      = poiName.isNotEmpty ? poiName : (_spotAddresses[key] ?? 'Sunny spot ${idx + 1}');
    final sunHoursLeft = (spot['sun_hours_left'] as int?) ?? 0;
    final sunUntil     = spot['sun_until'] as int?;
    final openingHours   = spot['_opening_hours'] as String? ?? '';
    final outdoorSeating = spot['_outdoor_seating'] as String? ?? '';
    final gps          = _gpsPosition;
    final distLabel    = gps != null ? _formatDistance(_distanceMeters(gps, LatLng(lat, lon))) : null;
    final category     = spot['_category'] as String? ?? '';
    final poiAmenity   = spot['_poi_amenity'] as String? ?? '';
    final (catIcon, catLabel) = category == 'park'
        ? (Icons.park, 'Park')
        : category == 'square'
            ? (Icons.location_city, 'Square')
            : poiAmenity.isNotEmpty
                ? (_poiIcon(poiAmenity), _poiLabel(poiAmenity))
                : (Icons.wb_sunny, 'Spot');
    final circColor = sunUntil != null ? const Color(0xFFFFD700) : Colors.grey.shade400;

    setState(() {
      _selectedSpot    = spot;
      _selectedSpotIdx = idx;
    });
    _panelScroll.jumpTo(0);
  }

  void _closeSpotDetail() {
    setState(() => _selectedSpot = null);
    if (_sunnySpots.isNotEmpty || _sunnyPois.isNotEmpty) {
      _suppressResultClear = true;
      final rc = _detailReturnCenter;
      final rz = _detailReturnZoom;
      if (rc != null && rz != null) {
        _mapController?.animateCamera(CameraUpdate.newLatLngZoom(rc, rz));
      }
    }
  }

  Widget _buildSpotDetail() {
    final spot   = _selectedSpot!;
    final idx    = _selectedSpotIdx;
    final lat    = spot['lat'] as double;
    final lon    = spot['lon'] as double;
    final key    = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
    final poiName = spot['_poi_name'] as String? ?? '';
    final address = poiName.isNotEmpty ? poiName : (_spotAddresses[key] ?? 'Sunny spot ${idx + 1}');
    final sunHoursLeft  = (spot['sun_hours_left'] as int?) ?? 0;
    final sunUntil      = spot['sun_until'] as int?;
    final openingHours  = spot['_opening_hours'] as String? ?? '';
    final outdoorSeating = spot['_outdoor_seating'] as String? ?? '';
    final gps      = _gpsPosition;
    final distLabel = gps != null ? _formatDistance(_distanceMeters(gps, LatLng(lat, lon))) : null;
    final category  = spot['_category'] as String? ?? '';
    final poiAmenity = spot['_poi_amenity'] as String? ?? '';
    final (catIcon, catLabel) = category == 'park'
        ? (Icons.park, 'Park')
        : category == 'square'
            ? (Icons.location_city, 'Square')
            : poiAmenity.isNotEmpty
                ? (_poiIcon(poiAmenity), _poiLabel(poiAmenity))
                : (Icons.wb_sunny, 'Spot');
    final circColor = sunUntil != null ? const Color(0xFFFFD700) : Colors.grey.shade400;
    final isSaved   = _savedSpots.any((s) => s['lat'] == lat && s['lon'] == lon);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Back + title row
        Row(children: [
          GestureDetector(
            onTap: _closeSpotDetail,
            child: Icon(Icons.arrow_back, size: 20, color: Colors.grey.shade600),
          ),
          const SizedBox(width: 10),
          Container(width: 26, height: 26,
            decoration: BoxDecoration(color: circColor, shape: BoxShape.circle),
            child: Center(child: Text('${idx + 1}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white))),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(address,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: 10),
        // Subtitle
        Wrap(spacing: 8, children: [
          if (distLabel != null) Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.directions_walk, size: 12, color: Colors.grey.shade500),
            const SizedBox(width: 3),
            Text(distLabel, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(sunUntil != null ? Icons.wb_sunny_outlined : Icons.nights_stay_outlined,
                size: 12, color: sunUntil != null ? Colors.orange.shade400 : Colors.grey.shade400),
            const SizedBox(width: 3),
            Text(
              sunUntil != null
                  ? (sunHoursLeft == 0
                      ? '< 1h · until ${sunUntil.toString().padLeft(2, '0')}:00'
                      : '$sunHoursLeft h · until ${sunUntil.toString().padLeft(2, '0')}:00')
                  : 'In shadow',
              style: TextStyle(fontSize: 12,
                  color: sunUntil != null ? Colors.orange.shade700 : Colors.grey.shade500),
            ),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(catIcon, size: 12, color: Colors.grey.shade400),
            const SizedBox(width: 3),
            Text(catLabel, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ]),
        ]),
        // Opening hours
        if (openingHours.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.schedule, size: 12, color: Colors.grey.shade400),
            const SizedBox(width: 5),
            Expanded(child: Text(openingHours,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (outdoorSeating == 'yes') ...[
              const SizedBox(width: 8),
              Icon(Icons.deck, size: 12, color: Colors.grey.shade400),
              const SizedBox(width: 3),
              Text('Terrace', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
          ]),
        ] else if (outdoorSeating == 'yes') ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.deck, size: 12, color: Colors.grey.shade400),
            const SizedBox(width: 5),
            Text('Outdoor seating', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ]),
        ],
        const SizedBox(height: 16),
        // Action buttons
        Row(children: [
          _sheetButton(
            icon: Icons.directions_walk, label: 'Navigate',
            color: Colors.orange.shade700,
            onTap: () {
              html.window.open(
                'https://www.google.com/maps/dir/?api=1&destination=$lat,$lon&travelmode=walking',
                '_blank');
            },
          ),
          const SizedBox(width: 8),
          _sheetButton(
            icon: isSaved ? Icons.favorite : Icons.favorite_outline,
            label: isSaved ? 'Saved' : 'Save',
            color: isSaved ? Colors.orange.shade800 : Colors.orange.shade600,
            onTap: () {
              setState(() {
                if (isSaved) {
                  _savedSpots.removeWhere((s) => s['lat'] == lat && s['lon'] == lon);
                } else {
                  _savedSpots.add({'lat': lat, 'lon': lon, 'address': address,
                      'sun_hours_left': sunHoursLeft, 'sun_until': sunUntil});
                }
                _persistSaved();
              });
            },
          ),
          const SizedBox(width: 8),
          _sheetButton(
            icon: Icons.share, label: 'Share',
            color: Colors.orange.shade500,
            onTap: () async {
              final server = Uri.base.queryParameters['server'] ?? 'https://sunspotme.duckdns.org';
              final link = 'https://coruscating-fenglisu-505ed3.netlify.app/'
                  '?server=${Uri.encodeComponent(server)}&lat=$lat&lon=$lon';
              await Clipboard.setData(ClipboardData(text: link));
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied to clipboard'),
                    duration: Duration(seconds: 2)));
            },
          ),
        ]),
      ]),
    );
  }

  Widget _buildSunTimeline(int sunHoursLeft, int? sunUntil) {
    const dayStart = 6;
    const dayEnd   = 21;
    final now      = _hour.toInt();
    final untilH   = sunUntil ?? now;
    final startH   = (untilH - sunHoursLeft).clamp(dayStart, dayEnd);

    return LayoutBuilder(builder: (_, constraints) {
      final total = (dayEnd - dayStart).toDouble();
      final w     = constraints.maxWidth;

      double frac(int h) => ((h - dayStart) / total).clamp(0.0, 1.0);

      final sunLeft   = w * frac(startH);
      final sunWidth  = (w * frac(untilH) - sunLeft).clamp(0.0, w - sunLeft);
      final nowX      = w * frac(now);

      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 18,
          child: Stack(children: [
            // Background track
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            // Sunny window
            Positioned(
              left: sunLeft, width: sunWidth, top: 0, bottom: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.orange.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            // Now marker
            Positioned(
              left: (nowX - 1).clamp(0.0, w - 2), width: 2, top: 0, bottom: 0,
              child: Container(color: Colors.orange.shade800),
            ),
          ]),
        ),
        const SizedBox(height: 3),
        // Hour labels
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (final h in [6, 9, 12, 15, 18, 21])
            Text('$h', style: TextStyle(fontSize: 9, color: Colors.grey.shade400)),
        ]),
      ]);
    });
  }

  void _showPointSheet(LatLng coords) {
    final lat = coords.latitude;
    final lon = coords.longitude;
    final key = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';

    // Start reverse geocoding in parallel
    _reverseGeocode(lat, lon).then((_) => _refreshPointSheet?.call());

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      barrierColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          _refreshPointSheet = () { if (ctx.mounted) setSheet(() {}); };

          final info      = _pointInfo;
          final loading   = _pointInfoLoading;
          final inShadow  = info == null ? null : (info['in_shadow'] as bool? ?? true);
          final sunCount  = info?['sun_hours_count'] as int? ?? 0;
          final periods   = (info?['sun_periods'] as List<dynamic>?) ?? [];
          final address   = _spotAddresses[key] ?? '';
          final isSaved   = _savedSpots.any((s) => s['lat'] == lat && s['lon'] == lon);
          final statusColor = inShadow == false ? const Color(0xFFFF8C00) : const Color(0xFF2d4862);

          String fmt(int h) => '${h.toString().padLeft(2, '0')}:00';

          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar + close button
                Row(
                  children: [
                    const Spacer(),
                    Container(
                      width: 36, height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          onTap: () => Navigator.of(ctx).pop(),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 10, left: 8),
                            child: Icon(Icons.close, size: 20, color: Colors.grey.shade400),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // Address
                Text(
                  address.isNotEmpty ? address : '${lat.toStringAsFixed(4)}°, ${lon.toStringAsFixed(4)}°',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),

                // Sun status
                if (loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))),
                  )
                else ...[
                  Row(children: [
                    Icon(
                      inShadow == false ? Icons.wb_sunny : Icons.nights_stay_outlined,
                      color: statusColor, size: 15,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      inShadow == false ? 'In Sun' : 'In Shadow',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: statusColor),
                    ),
                    const SizedBox(width: 12),
                    Icon(Icons.wb_sunny_outlined, size: 13, color: Colors.grey.shade400),
                    const SizedBox(width: 4),
                    Text(
                      sunCount == 0 ? 'No direct sun today' : '$sunCount h of sun today',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ]),
                  if (periods.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6, runSpacing: 4,
                      children: periods.map((p) {
                        final from = p['from'] as int;
                        final to   = p['to']   as int;
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('${fmt(from)} – ${fmt(to)}',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600,
                                  fontWeight: FontWeight.w500)),
                        );
                      }).toList(),
                    ),
                  ],
                ],

                const SizedBox(height: 20),
                // Action buttons
                Row(children: [
                  _sheetButton(
                    icon: Icons.directions_walk,
                    label: 'Navigate',
                    color: Colors.orange.shade700,
                    onTap: () {
                      html.window.open(
                        'https://www.google.com/maps/dir/?api=1'
                        '&destination=$lat,$lon&travelmode=walking',
                        '_blank',
                      );
                      Navigator.pop(ctx);
                    },
                  ),
                  const SizedBox(width: 10),
                  _sheetButton(
                    icon: isSaved ? Icons.favorite : Icons.favorite_outline,
                    label: isSaved ? 'Saved' : 'Save',
                    color: isSaved ? Colors.orange.shade800 : Colors.orange.shade600,
                    onTap: () {
                      setState(() {
                        if (isSaved) {
                          _savedSpots.removeWhere((s) => s['lat'] == lat && s['lon'] == lon);
                        } else {
                          _savedSpots.add({
                            'lat': lat, 'lon': lon,
                            'address': address.isNotEmpty ? address : '${lat.toStringAsFixed(4)}°N',
                            'sun_hours_left': sunCount,
                            'sun_until': periods.isNotEmpty ? (periods.last['to'] as int?) : null,
                          });
                        }
                        _persistSaved();
                      });
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(width: 10),
                  _sheetButton(
                    icon: Icons.share,
                    label: 'Share',
                    color: Colors.orange.shade500,
                    onTap: () async {
                      final server = Uri.base.queryParameters['server']
                          ?? 'https://sunspotme.duckdns.org';
                      final link = 'https://coruscating-fenglisu-505ed3.netlify.app/'
                          '?server=${Uri.encodeComponent(server)}&lat=$lat&lon=$lon';
                      await Clipboard.setData(ClipboardData(text: link));
                      Navigator.pop(ctx);
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied to clipboard'),
                            duration: Duration(seconds: 2)));
                    },
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    ).whenComplete(() {
      _refreshPointSheet = null;
      _hidePin();
      setState(() { _clickedPoint = null; _pointInfo = null; });
    });
  }

  Widget _sheetButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(height: 3),
              Text(label,
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        ),
      ),
    );
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
          accuracy: LocationAccuracy.low,
        ),
      ).timeout(const Duration(seconds: 30));
      return LatLng(pos.latitude, pos.longitude);
    } on TimeoutException {
      _showError('GPS: location timed out — try again');
      return null;
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
    _fetchWeather(newPos.latitude, newPos.longitude);
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
    if (_heatmapMode) return; // heatmap is shown — don't touch shadow layers

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
          // Small step — delay 200ms before dimming so fast cache hits
          // never show a flash of dim (user won't notice the wait).
          Future.delayed(const Duration(milliseconds: 200), () async {
            if (!mounted || !_loading) return;
            await _mapController?.setLayerProperties('shadow-l0-fill', FillLayerProperties(fillColor: '#3d5a70', fillOpacity: 0.15));
            await _mapController?.setLayerProperties('shadow-l1-fill', FillLayerProperties(fillColor: '#2e4d64', fillOpacity: 0.10));
            await _mapController?.setLayerProperties('shadow-l2-fill', FillLayerProperties(fillColor: '#1e3a52', fillOpacity: 0.08));
          });
        }
      }

      _lastFetchZoom = zoom;

      // Cache lookup — key matches server's _cache_key(hour, month, day, lat, lon, zoom)
      final cacheKey = '${zoom}_${_hour.toInt()}_${_selectedDate.month}_${_selectedDate.day}'
          '_${_currentCenter.latitude.toStringAsFixed(3)}'
          '_${_currentCenter.longitude.toStringAsFixed(3)}';
      final cached = _shadowResultCache[cacheKey];
      if (cached != null) {
        final elev   = (cached['elevation'] as num?)?.toDouble() ?? 0.0;
        final azim   = (cached['azimuth']   as num?)?.toDouble() ?? 0.0;
        final srHour = (cached['sunrise']   as num?)?.toDouble();
        final ssHour = (cached['sunset']    as num?)?.toDouble();
        if (cached['dark_area'] != null) {
          await _updateMapLayers(cached['dark_area'] as Map<String, dynamic>, elev);
        }
        _pillTimer?.cancel();
        if (mounted) setState(() {
          _elevation = elev; _azimuth = azim;
          _sunriseHour = srHour; _sunsetHour = ssHour;
          _loading = false; _showPill = false; _loadingProgress = 0.0;
        });
        if (!completer.isCompleted) completer.complete();
        return;
      }

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

      var resultReceived = false;

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
          resultReceived = true;
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
          // Store in client cache for instant replay (e.g. slider scrub back)
          _shadowResultCache[cacheKey] = result;
          if (_shadowResultCache.length > _shadowCacheMax) {
            _shadowResultCache.remove(_shadowResultCache.keys.first);
          }
          // Prefetch adjacent hours silently after a short idle delay
          Future.delayed(const Duration(milliseconds: 600), () {
            if (!mounted || _draggingSlider || _loading) return;
            final sr = _sunriseHour ?? 6.0;
            final ss = _sunsetHour ?? 20.0;
            for (final dh in [1, -1]) {
              final h = (_hour + dh).clamp(sr, ss).toInt();
              if (h != _hour.toInt()) _prefetchSilent(h, zoom);
            }
          });
          _pillTimer?.cancel();
          if (mounted) {
            setState(() {
              _elevation   = elev;
              _azimuth     = azim;
              _sunriseHour = srHour;
              _sunsetHour  = ssHour;
              // Clamp current hour to daylight window
              if (srHour != null && ssHour != null) {
                _hour = _hour.clamp(srHour, ssHour);
              }
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
        // If stream dropped before result arrived, restore shadow layers to
        // their pre-dim state so stale dimmed overlay doesn't persist.
        if (!resultReceived && _shadowLayersReady && _mapController != null) {
          _mapController!.setLayerProperties('shadow-l0-fill', FillLayerProperties(fillOpacity: 0.0));
          _mapController!.setLayerProperties('shadow-l1-fill', FillLayerProperties(fillOpacity: 0.0));
          _mapController!.setLayerProperties('shadow-l2-fill', FillLayerProperties(fillOpacity: 0.0));
        }
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

  // Silently pre-fetch an adjacent hour into the client cache.
  // Does not touch UI state or _fetchGen — pure background work.
  Future<void> _prefetchSilent(int hour, int zoom) async {
    if (!_mapReady || _mapController == null) return;
    final bounds = await _mapController!.getVisibleRegion();
    final prefetchKey = '${zoom}_${hour}_${_selectedDate.month}_${_selectedDate.day}'
        '_${_currentCenter.latitude.toStringAsFixed(3)}'
        '_${_currentCenter.longitude.toStringAsFixed(3)}';
    if (_shadowResultCache.containsKey(prefetchKey)) return;

    final uri = Uri.parse(
      '$flaskBaseUrl/shadow/stream'
      '?lat=${_currentCenter.latitude}'
      '&lon=${_currentCenter.longitude}'
      '&hour=$hour&minute=0'
      '&month=${_selectedDate.month}&day=${_selectedDate.day}'
      '&zoom=$zoom'
      '&minLat=${bounds.southwest.latitude}'
      '&minLon=${bounds.southwest.longitude}'
      '&maxLat=${bounds.northeast.latitude}'
      '&maxLon=${bounds.northeast.longitude}',
    );

    final es = html.EventSource(uri.toString());
    es.onMessage.listen((event) {
      final data = jsonDecode(event.data as String) as Map<String, dynamic>;
      if (data.containsKey('result')) {
        es.close();
        if (!_shadowResultCache.containsKey(prefetchKey)) {
          _shadowResultCache[prefetchKey] = data['result'] as Map<String, dynamic>;
          if (_shadowResultCache.length > _shadowCacheMax) {
            _shadowResultCache.remove(_shadowResultCache.keys.first);
          }
        }
      } else if (data.containsKey('error')) {
        es.close();
      }
    });
    es.onError.listen((_) => es.close());
  }

  Future<void> _updateMapLayers(Map<String, dynamic> geoJson, double elevation) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    final t   = elevation <= 0 ? 1.0 : (elevation.clamp(0.0, 60.0) / 60.0);
    final opL0 = elevation <= 0 ? 0.82 : 0.28 + t * 0.12;
    final opL1 = elevation <= 0 ? 0.0  : 0.28 + t * 0.15;
    final opL2 = elevation <= 0 ? 0.0  : 0.30 + t * 0.18;

    if (_shadowLayersReady) {
      try {
        // Update source data + opacity in-place — no remove/re-add, no flicker
        await ctrl.setGeoJsonSource('dark-area', geoJson);
        await ctrl.setLayerProperties('shadow-l0-fill', FillLayerProperties(fillColor: '#3d5a70', fillOpacity: opL0));
        await ctrl.setLayerProperties('shadow-l1-fill', FillLayerProperties(fillColor: '#2e4d64', fillOpacity: opL1));
        await ctrl.setLayerProperties('shadow-l2-fill', FillLayerProperties(fillColor: '#1e3a52', fillOpacity: opL2));
        return;
      } catch (_) {
        // Source was removed (style reload) — fall through to re-create
        _shadowLayersReady = false;
      }
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
      FillLayerProperties(fillColor: '#3d5a70', fillOpacity: opL0),
      filter: ['==', ['get', 'layer'], 'shadow-l0'],
      enableInteraction: false,
    );
    await ctrl.addLayer(
      'dark-area', 'shadow-l1-fill',
      FillLayerProperties(fillColor: '#2e4d64', fillOpacity: opL1),
      filter: ['==', ['get', 'layer'], 'shadow-l1'],
      enableInteraction: false,
    );
    await ctrl.addLayer(
      'dark-area', 'shadow-l2-fill',
      FillLayerProperties(fillColor: '#1e3a52', fillOpacity: opL2),
      filter: ['==', ['get', 'layer'], 'shadow-l2'],
      enableInteraction: false,
    );
    _shadowLayersReady = true;
  }

  // -------------------------------------------------------------------------
  // Animation
  // -------------------------------------------------------------------------

  void _toggle24h() {
    if (_animating) {
      // Cycle speed: 1×→2×→4×→stop
      if (_animSpeed == 1) { setState(() => _animSpeed = 2); return; }
      if (_animSpeed == 2) { setState(() => _animSpeed = 4); return; }
      setState(() { _animating = false; _animSpeed = 1; });
      return;
    }
    final start = _sunriseHour ?? 6.0;
    setState(() { _animating = true; _liveMode = false; _animSpeed = 1; _hour = start; });
    _run24hStep();
  }

  Future<void> _run24hStep() async {
    while (_animating) {
      await fetchShadows();
      if (_heatmapMode) await _fetchAndShowHeatmap();
      if (!_animating) break;
      final end = _sunsetHour ?? 20.0;
      if (_hour >= end) {
        setState(() => _animating = false);
        break;
      }
      // In heatmap mode the server is the bottleneck — no extra delay needed
      if (!_heatmapMode) {
        final ms = _animSpeed == 4 ? 100 : _animSpeed == 2 ? 300 : 600;
        await Future.delayed(Duration(milliseconds: ms));
      }
      if (!_animating) break;
      setState(() => _hour = _hour + 1.0);
    }
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
        final now = _viennaNow();
        _selectedDate = DateTime(now.year, now.month, now.day);
        _hour = (now.hour + now.minute / 60.0).clamp(0.0, 23.0);
      });
      fetchShadows();
      if (_heatmapMode) _fetchAndShowHeatmap();
      _liveTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (!mounted || !_liveMode) return;
        setState(() {
          final now = _viennaNow();
          _selectedDate = DateTime(now.year, now.month, now.day);
          _hour = (now.hour + now.minute / 60.0).clamp(0.0, 23.0);
        });
        fetchShadows();
        if (_heatmapMode) _fetchAndShowHeatmap();
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
    _mobileContentScroll.dispose();
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
    _fetchWeather(target.latitude, target.longitude);
  }

  @override
  Widget build(BuildContext context) {
    _screenWidth  = MediaQuery.of(context).size.width;
    _screenHeight = MediaQuery.of(context).size.height;
    final isMobile = _isMobile;
    const panelRightPad = 0;

    // Map area — used as Expanded child on mobile, full Scaffold body on desktop
    final mapArea = Stack(
      children: [
        AbsorbPointer(
          absorbing: _draggingSlider,
          child: MapLibreMap(
            styleString: mapStyle,
            initialCameraPosition: CameraPosition(target: _currentCenter, zoom: 13.0),
            onMapCreated:          _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onCameraIdle:          _onCameraIdle,
            onMapClick:            _onMapClick,
            trackCameraPosition:   true,
            compassEnabled:        false,
          ),
        ),

        // Radial vignette — fades shadow layer edges so rectangular boundary is hidden
        if (_shadowLayersReady && !_heatmapMode)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _VignettePainter()),
            ),
          ),

        // Tap-to-inspect hint badge (Saved tab only)
        if (_isMobile && _mobileTab == 3)
          Positioned(
            bottom: 24, left: 0, right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 8, offset: const Offset(0, 2))],
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.touch_app_outlined, size: 14, color: Colors.orange.shade500),
                    const SizedBox(width: 6),
                    Text('Tap map to inspect',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700,
                            fontWeight: FontWeight.w500)),
                  ]),
                ),
              ),
            ),
          ),

        // Number labels overlaid on map dots
        IgnorePointer(
          child: Stack(children: [
            ..._sunnySpotScreenPos.asMap().entries.map((e) => Positioned(
              left: e.value.dx - 5,
              top: e.value.dy - 6,
              child: Text('${e.key + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.bold, height: 1)),
            )),
            ..._tourMarkerScreenPos.asMap().entries.map((e) => Positioned(
              left: e.value.dx - 5,
              top: e.value.dy - 6,
              child: Text('${e.key + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.bold, height: 1)),
            )),
            ..._poiScreenPos.asMap().entries.map((e) => Positioned(
              left: e.value.dx - 5,
              top: e.value.dy - 6,
              child: Text('${e.key + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.bold, height: 1)),
            )),
          ]),
        ),

        // Search bar
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          top: 12, left: 12, right: 12,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _ignoreNextMapClick = true,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 10, offset: const Offset(0, 3))],
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
                        onSubmitted: (v) { if (v.trim().isNotEmpty) _runSearch(v.trim()); },
                        textInputAction: TextInputAction.search,
                        keyboardType: TextInputType.text,
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
                        child: SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange.shade400)),
                      )
                    else if (_searchController.text.isNotEmpty)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () { _searchController.clear(); setState(() => _searchResults = []); },
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
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 10, offset: const Offset(0, 4))],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _searchResults.asMap().entries.map((entry) {
                      final i      = entry.key;
                      final result = entry.value;
                      final parts  = (result['display_name'] as String).split(',');
                      final title  = parts.first.trim();
                      final sub    = parts.length > 1 ? parts.skip(1).take(2).map((s) => s.trim()).join(', ') : '';
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (i > 0) Divider(height: 1, color: Colors.grey.shade100),
                          GestureDetector(
                            onTap: () => _selectSearchResult(result),
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
        ),

        // Loading bar (top)
        if (_loading)
          Positioned(
            top: 0, left: 0, right: panelRightPad.toDouble(),
            child: LinearProgressIndicator(
              value: _loadingProgress > 0 ? _loadingProgress : null,
              minHeight: 3,
              backgroundColor: Colors.transparent,
              color: Colors.orangeAccent,
            ),
          ),

        // Weather widget — top-right, below search bar
        Positioned(
          top: 64, right: 12,
          child: _buildWeatherWidget(),
        ),

        // Loading pill
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          bottom: 24, left: 0, right: panelRightPad.toDouble(),
          child: Center(child: _buildLoadingPill()),
        ),

        // Heatmap toggle — top-left, below search bar
        Positioned(
          top: 68, left: 16,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _ignoreNextMapClick = true,
            child: FloatingActionButton.small(
              heroTag: 'heatmap',
              onPressed: _toggleHeatmap,
              backgroundColor: _heatmapMode ? Colors.orange : Colors.white,
              foregroundColor: _heatmapMode ? Colors.white : Colors.black87,
              elevation: 2,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              child: _heatmapLoading
                  ? SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _heatmapMode ? Colors.white : Colors.orange,
                      ),
                    )
                  : Icon(Icons.layers,
                      size: 20,
                      color: _heatmapMode ? Colors.white : Colors.orange),
            ),
          ),
        ),

        // GPS button — bottom-right
        Positioned(
          bottom: 16, right: 16,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _ignoreNextMapClick = true,
            child: FloatingActionButton.small(
              onPressed: _goToMyLocation,
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              elevation: 2,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              child: const Icon(Icons.my_location, size: 20),
            ),
          ),
        ),

        // Zoom + — mirrors heatmap toggle position
        Positioned(
          bottom: 68, left: 16,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _ignoreNextMapClick = true,
            child: _buildZoomButton(Icons.add, () async {
              final cam = _mapController?.cameraPosition;
              if (cam == null) return;
              await _mapController?.animateCamera(CameraUpdate.newCameraPosition(
                  CameraPosition(target: cam.target, zoom: (cam.zoom + 1).clamp(1, 20))));
            }),
          ),
        ),

        // Zoom − — mirrors GPS button position
        Positioned(
          bottom: 16, left: 16,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _ignoreNextMapClick = true,
            child: _buildZoomButton(Icons.remove, () async {
              final cam = _mapController?.cameraPosition;
              if (cam == null) return;
              await _mapController?.animateCamera(CameraUpdate.newCameraPosition(
                  CameraPosition(target: cam.target, zoom: (cam.zoom - 1).clamp(1, 20))));
            }),
          ),
        ),

        // Error banner
        if (_errorMessage != null)
          Positioned(
            bottom: 80, left: 16, right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(8)),
              child: Text(_errorMessage!, style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),

      ],
    );

    return Scaffold(
      body: isMobile
          ? LayoutBuilder(builder: (ctx, constraints) {
              final totalH    = constraints.maxHeight;
              const collapsedH = 256.0;
              final bottomH   = _panelExpanded ? totalH : collapsedH;
              final mapH      = totalH - bottomH;
              return Column(children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeInOut,
                  height: mapH,
                  child: mapArea,
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeInOut,
                  height: bottomH,
                  child: _buildMobileBottom(),
                ),
              ]);
            })
          : Row(children: [
              Expanded(child: mapArea),
              SizedBox(width: 280, child: _buildDesktopSidebar()),
            ]),
    );
  }

  Widget _buildZoomButton(IconData icon, VoidCallback onTap) {
    return FloatingActionButton.small(
      heroTag: icon == Icons.add ? 'zoom_in' : 'zoom_out',
      onPressed: onTap,
      backgroundColor: Colors.white,
      foregroundColor: Colors.black87,
      elevation: 2,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      child: Icon(icon, size: 20),
    );
  }

  Widget _buildLoadingPill() {
    final visible = _showPill || _heatmapLoading;
    final rawStage = _loadingStage;
    // At low zoom, hide verbose "Projecting X buildings" — show generic label
    final label = _heatmapLoading
        ? 'Sun Map…'
        : (rawStage.isEmpty
            ? 'Loading…'
            : (_lastFetchZoom <= 13 && rawStage.startsWith('Projecting')
                ? 'Computing…'
                : rawStage));
    final pct     = _heatmapLoading ? null : (_loadingProgress > 0 ? _loadingProgress : null);
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      child: IgnorePointer(
        ignoring: !visible,
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
                    label,
                    style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500, color: Colors.black87,
                    ),
                  ),
                  if (!_heatmapLoading) ...[
                    const SizedBox(width: 10),
                    Text(
                      '${(_loadingProgress * 100).toInt()}%',
                      style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold, color: Colors.orange,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 7),
              SizedBox(
                width: 210,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
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

  Widget _buildDesktopSidebar() {
    const tabs = [
      (Icons.access_time,       'Time'),
      (Icons.wb_sunny_outlined, 'Spots'),
      (Icons.route,             'Tour'),
      (Icons.favorite_outline,  'Saved'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(-4, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // Content area
          Expanded(
            child: SingleChildScrollView(
              controller: _panelScroll,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: _buildMobileTabContent(),
            ),
          ),
          // Tab bar
          Divider(height: 1, color: Colors.grey.shade200),
          SizedBox(
            height: 56,
            child: Row(
              children: tabs.asMap().entries.map((entry) {
                final i     = entry.key;
                final icon  = entry.value.$1;
                final label = entry.value.$2;
                final sel   = _mobileTab == i;
                return Expanded(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () {
                        if (i != 1) {
                          setState(() { _sunnySpots = []; _sunnyPois = []; _sunnySpotScreenPos = []; _poiScreenPos = []; });
                          _clearSunnySpots();
                          _clearPoiMarkers();
                          _lastSearchCenter = null;
                          _lastSearchZoom   = null;
                        }
                        setState(() { _mobileTab = i; _selectedSpot = null; });
                        _panelScroll.jumpTo(0);
                        if (i == 3) _refreshSavedSunny();
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: sel ? Colors.orange.withValues(alpha: 0.12) : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(icon, size: 22,
                                color: sel ? Colors.orange : Colors.grey.shade400),
                          ),
                          const SizedBox(height: 1),
                          Text(label,
                              style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w600,
                                color: sel ? Colors.orange : Colors.grey.shade400,
                              )),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
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
              _buildTimeSlider(),
              const SizedBox(height: 16),
              _buildDateSection(),
              const Divider(height: 28),
              _buildFindSunnySpotsSection(),
              const Divider(height: 28),
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
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Icon(_timePeriodIcon, color: Colors.orange.shade300, size: 14),
        const SizedBox(width: 5),
        Text(_timePeriod,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w600,
                color: Colors.grey.shade400, letterSpacing: 1.1)),
        const Spacer(),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: _hour, end: _hour),  // begin=_hour: no sweep-from-midnight on load; subsequent changes animate from current value
          duration: const Duration(milliseconds: 350),
          builder: (context, value, _) {
            return Text(
              _formatDisplayHour(value),
              style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w300,
                color: _draggingSlider ? Colors.orange : Colors.black87,
                letterSpacing: -0.5,
              ),
            );
          },
        ),
      ],
    );
  }

  // ---- Time slider ----
  Widget _buildTimeSlider() {
    final minH      = _sunriseHour ?? 5.0;
    final maxH      = _sunsetHour  ?? 22.0;
    final divisions = (maxH - minH).round().clamp(1, 23);
    final sliderVal = _hour.clamp(minH, maxH);
    final noonInRange = minH < 12.0 && maxH > 12.0;

    // Slider full width
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: _liveMode ? Colors.red.shade300 : Colors.orange,
        inactiveTrackColor: _liveMode ? Colors.red.shade100 : Colors.orange.shade100,
        thumbColor: _liveMode ? Colors.red.shade400 : Colors.white,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        overlayColor: (_liveMode ? Colors.red : Colors.orange).withValues(alpha: 0.2),
      ),
      child: Slider(
        value: sliderVal,
        min: minH, max: maxH, divisions: divisions,
        onChangeStart: (_) {
          _liveTimer?.cancel();
          setState(() { _draggingSlider = true; _liveMode = false; });
          _setMapPointerEvents(false);
        },
        onChanged:   (v) => setState(() => _hour = v),
        onChangeEnd: (_) {
          setState(() => _draggingSlider = false);
          _setMapPointerEvents(true);
          fetchShadows();
          if (_heatmapMode) _fetchAndShowHeatmap();
        },
      ),
    );

    // Single row: ☀ sunrise · [LIVE] · 12 PM · [24h] · 🌙 sunset
    final labelsRow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // sunrise
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.wb_sunny_outlined, size: 9, color: Colors.orange.shade400),
            const SizedBox(width: 3),
            Text(_formatSliderHour(minH),
                style: TextStyle(fontSize: 10, color: Colors.orange.shade400, fontWeight: FontWeight.w500)),
          ]),
          // LIVE button
          GestureDetector(
            onTap: _toggleLiveMode,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: _liveMode ? Colors.red.shade400 : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _liveMode ? Colors.red.shade400 : Colors.grey.shade300,
                  width: 1,
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 5, height: 5,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: _liveMode ? Colors.white : Colors.red.shade300,
                    shape: BoxShape.circle,
                  ),
                ),
                Text('LIVE', style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600,
                  color: _liveMode ? Colors.white : Colors.grey.shade500,
                  letterSpacing: 0.6,
                )),
              ]),
            ),
          ),
          // noon
          if (noonInRange)
            Text('12 PM', style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
          // 24h button
          GestureDetector(
            onTap: _toggle24h,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: _animating ? Colors.orange.shade400 : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _animating ? Colors.orange.shade400 : Colors.grey.shade300,
                  width: 1,
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                  _animating ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  size: 10,
                  color: _animating ? Colors.white : Colors.grey.shade500,
                ),
                const SizedBox(width: 2),
                Text(_animating ? '${_animSpeed}×' : '24h',
                    style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w600,
                      color: _animating ? Colors.white : Colors.grey.shade500,
                    )),
              ]),
            ),
          ),
          // sunset
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.nightlight_round, size: 9, color: Colors.blueGrey.shade300),
            const SizedBox(width: 3),
            Text(_formatSliderHour(maxH),
                style: TextStyle(fontSize: 10, color: Colors.blueGrey.shade300, fontWeight: FontWeight.w500)),
          ]),
        ],
      ),
    );

    return Column(children: [
      slider,
      labelsRow,
    ]);
  }

  String _formatSliderHour(double hour) {
    final h = hour.toInt().clamp(0, 23);
    final m = ((hour - h) * 60).round();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  // -------------------------------------------------------------------------
  // Sunny Tour
  // -------------------------------------------------------------------------

  static const double _walkMsPerMeter = 60.0 / 80.0; // ~80 m/min walking speed

  List<Map<String, dynamic>> _orderByNearestNeighbor(
      List<Map<String, dynamic>> spots, LatLng start) {
    final remaining = List<Map<String, dynamic>>.from(spots);
    final ordered   = <Map<String, dynamic>>[];
    LatLng current  = start;
    while (remaining.isNotEmpty) {
      int    ni = 0;
      double nd = double.infinity;
      for (int i = 0; i < remaining.length; i++) {
        final d = _distanceMeters(current,
            LatLng(remaining[i]['lat'] as double, remaining[i]['lon'] as double));
        if (d < nd) { nd = d; ni = i; }
      }
      ordered.add(remaining[ni]);
      current = LatLng(ordered.last['lat'] as double, ordered.last['lon'] as double);
      remaining.removeAt(ni);
    }
    return ordered;
  }

  Future<void> _buildTour() async {
    if (_tourBuilding) return;
    setState(() { _tourBuilding = true; _tourSpots = []; });
    await _clearSunnySpots();

    try {
      final date = _selectedDate;
      final uri  = Uri.parse(
        '$flaskBaseUrl/find_sunny_spots'
        '?lat=${_currentCenter.latitude}'
        '&lon=${_currentCenter.longitude}'
        '&hour=${_hour.toInt()}'
        '&minute=${((_hour * 60).toInt() % 60)}'
        '&month=${date.month}&day=${date.day}'
        '&n=8',
      );
      final res  = await http.get(uri).timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final raw  = (data['spots'] as List? ?? []).cast<Map<String, dynamic>>()
          .map((s) => <String, dynamic>{
                'lat':            (s['lat']  as num).toDouble(),
                'lon':            (s['lon']  as num).toDouble(),
                'sun_hours_left': (s['sun_hours_left'] as num?)?.toInt() ?? 0,
                'sun_until':      s['sun_until'] as int?,
              })
          .toList();

      if (raw.isEmpty) {
        setState(() => _tourBuilding = false);
        _showError('No sun at this hour — move the time slider');
        return;
      }

      // Order nearest-neighbor, then trim to walking budget
      final start   = _gpsPosition ?? _currentCenter;
      final ordered = _orderByNearestNeighbor(raw, start);
      final budget  = _tourDuration * 80.0;   // meters at 80 m/min
      double walked = 0;
      LatLng cur    = start;
      final kept    = <Map<String, dynamic>>[];
      for (final s in ordered) {
        final pos = LatLng(s['lat'] as double, s['lon'] as double);
        final d   = _distanceMeters(cur, pos);
        if (walked + d > budget) break;
        walked += d;
        kept.add({ ...s, '_dist': d.round() });
        cur = pos;
      }
      if (kept.isEmpty) kept.add({ ...ordered.first, '_dist':
          _distanceMeters(start, LatLng(ordered.first['lat'] as double,
              ordered.first['lon'] as double)).round() });

      setState(() => _tourSpots = kept);
      _geocodeSpots(kept);
      await _drawTourLine(start, kept);
      await _refreshTourMarkerPositions();
    } catch (e) {
      _showError('Tour error: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _tourBuilding = false);
    }
  }

  Future<void> _drawTourLine(LatLng start, List<Map<String, dynamic>> spots) async {
    final ctrl = _mapController;
    if (ctrl == null) return;

    // Line
    final coords = [
      [start.longitude, start.latitude],
      ...spots.map((s) => [s['lon'] as double, s['lat'] as double]),
    ];
    final lineGeojson = {
      'type': 'FeatureCollection',
      'features': [{
        'type': 'Feature',
        'geometry': {'type': 'LineString', 'coordinates': coords},
        'properties': {},
      }],
    };

    // Markers — numbered points for each stop
    final markerFeatures = spots.asMap().entries.map((e) => {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [e.value['lon'], e.value['lat']],
      },
      'properties': {'index': e.key + 1},
    }).toList();
    final markerGeojson = {
      'type': 'FeatureCollection',
      'features': markerFeatures,
    };

    if (_tourLayerReady) {
      await ctrl.setGeoJsonSource('tour-route', lineGeojson);
      await ctrl.setGeoJsonSource('tour-markers', markerGeojson);
    } else {
      // Line
      await ctrl.addSource('tour-route', GeojsonSourceProperties(data: lineGeojson));
      await ctrl.addLayer(
        'tour-route', 'tour-line',
        LineLayerProperties(lineColor: '#FF8C00', lineWidth: 3.0,
            lineDasharray: [6.0, 4.0]),
        enableInteraction: false,
      );
      // Markers
      await ctrl.addSource('tour-markers', GeojsonSourceProperties(data: markerGeojson));
      await ctrl.addLayer(
        'tour-markers', 'tour-marker-glow',
        CircleLayerProperties(
          circleRadius: 20,
          circleColor: '#FF8C00',
          circleOpacity: 0.25,
          circleStrokeWidth: 0,
        ),
        enableInteraction: false,
      );
      await ctrl.addLayer(
        'tour-markers', 'tour-marker-dot',
        CircleLayerProperties(
          circleRadius: 10,
          circleColor: '#FF8C00',
          circleOpacity: 1.0,
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFFFF',
        ),
        enableInteraction: false,
      );
      _tourLayerReady = true;
    }
  }

  Future<void> _clearTourLine() async {
    if (mounted) setState(() => _tourMarkerScreenPos = []);
    if (!_tourLayerReady) return;
    final empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};
    await _mapController?.setGeoJsonSource('tour-route', empty);
    await _mapController?.setGeoJsonSource('tour-markers', empty);
  }

  Widget _buildTourTab() {
    final totalDist = _tourSpots.fold<int>(
        0, (sum, s) => sum + ((s['_dist'] as num?)?.toInt() ?? 0));
    final totalMin  = (totalDist / 80).round();
    final totalSun  = _tourSpots.fold<int>(
        0, (sum, s) => sum + ((s['sun_hours_left'] as num?)?.toInt() ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Duration chips + clear
        Wrap(alignment: WrapAlignment.center, runSpacing: 6, children: [
          ...[15, 30, 60].map((min) {
            final sel = _tourDuration == min;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => setState(() => _tourDuration = min),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? Colors.orange : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text('$min min',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: sel ? Colors.white : Colors.black54)),
                ),
              ),
            );
          }),
          if (_tourSpots.isNotEmpty || _tourBuilding)
            GestureDetector(
              onTap: () {
                setState(() { _tourSpots = []; _tourMarkerScreenPos = []; });
                _clearTourLine();
              },
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
                child: Icon(Icons.close, size: 16, color: Colors.grey.shade500),
              ),
            ),
        ]),
        const SizedBox(height: 10),

        // Plan button — same style as Find sunny spots
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: _tourBuilding ? null : _buildTour,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _tourBuilding ? Colors.orange : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _tourBuilding
                      ? const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(Icons.wb_sunny_outlined, size: 15, color: Colors.black54),
                  const SizedBox(width: 6),
                  Text(_tourBuilding ? 'Planning...' : 'Plan sunny tour',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: _tourBuilding ? Colors.white : Colors.black54)),
                ]),
              ),
            ),
          ),
        ]),

        // Results
        if (_tourSpots.isNotEmpty) ...[
          const SizedBox(height: 16),
          // Summary row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _tourStat(Icons.straighten, '${totalDist}m'),
                _tourStat(Icons.timer_outlined, '~$totalMin min'),
                _tourStat(Icons.wb_sunny_outlined, '~${totalSun}h sun'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Spot list
          ..._tourSpots.asMap().entries.map((e) {
            final idx  = e.key;
            final spot = e.value;
            final lat  = spot['lat'] as double;
            final lon  = spot['lon'] as double;
            final key  = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
            final addr = _spotAddresses[key] ?? 'Spot ${idx + 1}';
            final dist = (spot['_dist'] as num?)?.toInt() ?? 0;
            final sunH = spot['sun_hours_left'] as int? ?? 0;
            final until = spot['sun_until'] as int?;
            final walkMin = (dist / 80).round();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Walk arrow (except first)
                if (idx > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 11, top: 2, bottom: 2),
                    child: Row(children: [
                      Icon(Icons.arrow_downward, size: 12, color: Colors.grey.shade400),
                      const SizedBox(width: 4),
                      Text('$walkMin min walk · ${dist}m',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                    ]),
                  ),
                GestureDetector(
                  onTap: () => _mapController?.animateCamera(
                      CameraUpdate.newLatLngZoom(LatLng(lat, lon), 17.0)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Container(
                        width: 20, height: 20,
                        decoration: const BoxDecoration(
                            color: Color(0xFFFFD700), shape: BoxShape.circle),
                        child: Center(child: Text('${idx + 1}',
                            style: const TextStyle(fontSize: 10,
                                fontWeight: FontWeight.bold, color: Colors.white))),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(addr, style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500,
                              color: Color(0xFF1A1A1A)),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(
                            until != null
                                ? '$sunH h · until ${until.toString().padLeft(2,'0')}:00'
                                : '$sunH h of sun',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          ),
                        ],
                      )),
                    ]),
                  ),
                ),
              ],
            );
          }),
        ],
      ],
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black.withValues(alpha: 0.15), width: 0.5),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.black87)),
    ]);
  }

  Widget _tourStat(IconData icon, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: Colors.grey.shade500),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 12,
          fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
    ]);
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


  IconData _poiIcon(String amenity) {
    if (amenity.contains('cafe'))        return Icons.local_cafe;
    if (amenity.contains('park') || amenity.contains('garden')) return Icons.park;
    if (amenity.contains('square') || amenity.contains('pedestrian')) return Icons.location_city;
    if (amenity.contains('bar') || amenity.contains('pub') || amenity.contains('beer')) return Icons.sports_bar;
    if (amenity.contains('restaurant') || amenity.contains('fast_food')) return Icons.restaurant;
    return Icons.place;
  }

  // Human-readable type name used as display name fallback when OSM name is absent
  String _poiTypeLabel(String amenity) {
    if (amenity.contains('cafe'))        return '☕ Café';
    if (amenity.contains('beer_garden')) return '🌿 Beer Garden';
    if (amenity.contains('playground'))  return '🛝 Playground';
    if (amenity.contains('park'))        return '🌳 Park';
    if (amenity.contains('garden'))      return '🌳 Garden';
    if (amenity.contains('square') || amenity.contains('pedestrian')) return '⛲ Square';
    if (amenity.contains('square') || amenity.contains('pedestrian')) return '🏛️ Square';
    if (amenity.contains('bar') || amenity.contains('pub')) return '🍺 Bar';
    if (amenity.contains('restaurant'))  return '🍽️ Restaurant';
    if (amenity.contains('fast_food'))   return '🍔 Food';
    return '☀️ Spot';
  }

  String _poiLabel(String amenity) {
    if (amenity.contains('cafe'))        return 'Café';
    if (amenity.contains('park') || amenity.contains('garden')) return 'Park';
    if (amenity.contains('square') || amenity.contains('pedestrian')) return 'Square';
    if (amenity.contains('beer_garden')) return 'Beer garden';
    if (amenity.contains('bar') || amenity.contains('pub')) return 'Bar';
    if (amenity.contains('restaurant'))  return 'Restaurant';
    if (amenity.contains('fast_food'))   return 'Food';
    return 'Spot';
  }

  // ---- Find sunny spots / places ----
  Widget _buildFindSunnySpotsSection() {
    // Mode toggle
    Widget modeToggle = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _modeBtn('Spots', Icons.wb_sunny_outlined, !_placesMode, () { setState(() { _placesMode = false; _sunnyPois = []; _poisNoResults = false; }); _clearPoiMarkers(); }),
      const SizedBox(width: 8),
      _modeBtn('Places', Icons.storefront_outlined, _placesMode, () { setState(() { _placesMode = true; _sunnySpots = []; _spotsNoResults = false; }); _clearSunnySpots(); }),
    ]);

    if (!_placesMode) {
      // ── Spots mode ──────────────────────────────────────────────────────────
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        modeToggle,
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: _findingSunnySpots ? null : _findSunnySpots,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _findingSunnySpots ? Colors.orange : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _findingSunnySpots
                      ? SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(Icons.wb_sunny_outlined, size: 15,
                          color: _findingSunnySpots ? Colors.white : Colors.black54),
                  const SizedBox(width: 6),
                  Text(_findingSunnySpots ? 'Searching...' : 'Find sunny spots',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: _findingSunnySpots ? Colors.white : Colors.black54)),
                ]),
              ),
            ),
          ),
          if (_sunnySpots.isNotEmpty) ...[
            const SizedBox(width: 8),
            IconButton(
              onPressed: _clearSunnySpots,
              icon: const Icon(Icons.close, size: 16),
              style: IconButton.styleFrom(
                backgroundColor: Colors.grey.shade100,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              padding: const EdgeInsets.all(10),
            ),
          ],
        ]),
        if (_spotsZoomHint) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.zoom_in, size: 14, color: Colors.grey),
            const SizedBox(width: 6),
            Text('Zoom in to see results', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
        ],
        if (_spotsNoResults) ...[
          const SizedBox(height: 16),
          _buildNoResultsMessage(),
        ],
        if (_sunnySpots.isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._sunnySpots.asMap().entries.map((e) {
            final idx      = e.key;
            final spot     = e.value;
            final spotPos  = LatLng(spot['lat'] as double, spot['lon'] as double);
            final sunH     = (spot['sun_hours_left'] as int?) ?? 0;
            final sunUntil = spot['sun_until'] as int?;
            final gps      = _gpsPosition;
            final distLbl  = gps != null ? _formatDistance(_distanceMeters(gps, spotPos)) : null;
            final addrKey  = '${spotPos.latitude.toStringAsFixed(6)},${spotPos.longitude.toStringAsFixed(6)}';
            final poiName  = (spot['_poi_name'] as String? ?? '');
            final address  = poiName.isNotEmpty ? poiName : (_spotAddresses[addrKey] ?? 'Sunny spot ${idx + 1}');
            final isSaved  = _savedSpots.any((s) => s['lat'] == spotPos.latitude && s['lon'] == spotPos.longitude);
            final category = spot['_category'] as String? ?? 'spot';
            final (catIcon, catLabel, catColor) = switch (category) {
              'park'   => (Icons.park,          'Park',   const Color(0xFF4CAF50)),
              'square' => (Icons.location_city, 'Square', const Color(0xFF7B61FF)),
              _        => (Icons.wb_sunny,      'Spot',   const Color(0xFFFF9800)),
            };
            final inShadow = sunUntil == null;
            final sunLbl = inShadow
                ? 'In shadow'
                : sunH == 0
                    ? '< 1h · until ${sunUntil.toString().padLeft(2,'0')}:00'
                    : '$sunH h · until ${sunUntil.toString().padLeft(2,'0')}:00';
            return _spotCard(
              circleChild: Text('${idx + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
              circleColor: inShadow ? Colors.grey.shade400 : const Color(0xFFFFD700),
              address: address,
              distLabel: distLbl,
              sunLabel: sunLbl,
              categoryIcon: catIcon,
              categoryLabel: catLabel,
              isSaved: isSaved,
              inShadow: inShadow,
              onTap: () => _selectSpot(spot, idx),
            );
          }),
        ],
      ]);
    }

    // ── Places mode ─────────────────────────────────────────────────────────
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      modeToggle,
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: GestureDetector(
            onTap: _loadingPois ? null : _findSunnyPois,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: _loadingPois ? Colors.orange : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _loadingPois
                    ? SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(Icons.storefront_outlined, size: 15, color: Colors.black54),
                const SizedBox(width: 6),
                Text(_loadingPois ? 'Searching...' : 'Find sunny places',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: _loadingPois ? Colors.white : Colors.black54)),
              ]),
            ),
          ),
        ),
        if (_sunnyPois.isNotEmpty) ...[
          const SizedBox(width: 8),
          IconButton(
            onPressed: () { setState(() => _sunnyPois = []); _clearPoiMarkers(); },
            icon: const Icon(Icons.close, size: 16),
            style: IconButton.styleFrom(
              backgroundColor: Colors.grey.shade100,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            padding: const EdgeInsets.all(10),
          ),
        ],
      ]),
      if (_poisNoResults) ...[
        const SizedBox(height: 16),
        _buildNoResultsMessage(),
      ],
      if (_sunnyPois.isNotEmpty) ...[
        const SizedBox(height: 10),
        ..._sunnyPois.asMap().entries.map((e) {
          final idx     = e.key;
          final poi     = e.value;
          final lat     = poi['lat'] as double;
          final lon     = poi['lon'] as double;
          final name    = (poi['name'] as String? ?? '').isNotEmpty
              ? poi['name'] as String
              : (poi['amenity'] as String? ?? 'Place ${idx + 1}');
          final dist          = poi['dist'] as int? ?? 0;
          final amenity       = poi['amenity'] as String? ?? '';
          final sunH          = (poi['sun_hours_left'] as int?) ?? 0;
          final sunUntil      = poi['sun_until'] as int?;
          final openingHours  = poi['opening_hours'] as String? ?? '';
          final outdoorSeating = poi['outdoor_seating'] as String? ?? '';
          final isSaved  = _savedSpots.any((s) => s['lat'] == lat && s['lon'] == lon);
          final catLabel = _poiLabel(amenity);
          final catIcon  = _poiIcon(amenity);
          final inShadow = sunUntil == null;
          final sunLbl = inShadow
              ? 'In shadow'
              : sunH == 0
                  ? '< 1h · until ${sunUntil.toString().padLeft(2,'0')}:00'
                  : '$sunH h · until ${sunUntil.toString().padLeft(2,'0')}:00';
          return _spotCard(
            circleChild: Text('${idx + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
            circleColor: inShadow ? Colors.grey.shade400 : const Color(0xFFFF8C00),
            address: name,
            distLabel: _formatDistance(dist.toDouble()),
            sunLabel: sunLbl,
            categoryIcon: catIcon,
            categoryLabel: catLabel,
            isSaved: isSaved,
            inShadow: inShadow,
            onTap: () => _selectSpot({
              'lat': lat, 'lon': lon,
              'sun_hours_left': sunH, 'sun_until': sunUntil,
              '_poi_name': name, '_poi_amenity': amenity,
              '_opening_hours': openingHours,
              '_outdoor_seating': outdoorSeating,
            }, idx),
          );
        }),
      ],
    ]);
  }

  Widget _modeBtn(String label, IconData icon, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? Colors.orange : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14,
              color: active ? Colors.white : Colors.black54),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600,
            color: active ? Colors.white : Colors.black54,
          )),
        ]),
      ),
    );
  }

  Widget _spotCard({
    required Widget circleChild,
    required Color circleColor,
    required String address,
    required String? distLabel,
    required String sunLabel,
    required bool isSaved,
    required VoidCallback onTap,
    IconData? categoryIcon,
    String? categoryLabel,
    bool inShadow = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Container(
                width: 26, height: 26,
                decoration: BoxDecoration(color: circleColor, shape: BoxShape.circle),
                child: Center(child: circleChild),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(address,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                          color: Color(0xFF1A1A1A)),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Row(children: [
                    if (distLabel != null) ...[
                      Icon(Icons.directions_walk, size: 11, color: Colors.grey.shade400),
                      const SizedBox(width: 2),
                      Text(distLabel, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      const SizedBox(width: 5),
                      Text('·', style: TextStyle(fontSize: 11, color: Colors.grey.shade300)),
                      const SizedBox(width: 5),
                    ],
                    Icon(inShadow ? Icons.nights_stay_outlined : Icons.wb_sunny_outlined,
                        size: 11, color: inShadow ? Colors.grey.shade400 : Colors.orange.shade400),
                    const SizedBox(width: 2),
                    Flexible(child: Text(sunLabel, style: TextStyle(fontSize: 11,
                        color: inShadow ? Colors.grey.shade400 : Colors.orange.shade600),
                        overflow: TextOverflow.ellipsis)),
                    if (categoryIcon != null) ...[
                      const SizedBox(width: 5),
                      Text('·', style: TextStyle(fontSize: 11, color: Colors.grey.shade300)),
                      const SizedBox(width: 5),
                      Icon(categoryIcon, size: 11, color: Colors.grey.shade400),
                      const SizedBox(width: 2),
                      Flexible(child: Text(categoryLabel ?? '', style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          overflow: TextOverflow.ellipsis)),
                    ],
                  ]),
                ]),
              ),
              if (isSaved) ...[const SizedBox(width: 4), Icon(Icons.favorite, size: 14, color: Colors.red.shade300)],
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: Colors.grey.shade300),
            ]),
          ),
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
          Expanded(child: _buildSunRadar()),
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

  Widget _buildSunRadar() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.explore_outlined, size: 12, color: Colors.grey),
          const SizedBox(width: 4),
          const Text('DIRECTION', style: TextStyle(
              fontSize: 10, color: Colors.grey,
              fontWeight: FontWeight.w600, letterSpacing: 0.8)),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          height: 44, width: double.infinity,
          child: CustomPaint(
            painter: _SunRadarPainter(azimuth: _azimuth, elevation: _elevation),
          ),
        ),
      ]),
    );
  }

  Widget _buildNoResultsMessage() {
    return Column(children: [
      Icon(Icons.wb_cloudy_outlined, size: 32, color: Colors.grey.shade300),
      const SizedBox(height: 8),
      Text('No sunny spots found here',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      Text('Everything is in shadow right now.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
    ]);
  }

  // =========================================================================
  // Mobile bottom UI — separated from map (no overlap = no panning conflict)
  // =========================================================================

  Widget _buildMobileBottom() {
    const tabs = [
      (Icons.access_time,       'Time'),
      (Icons.wb_sunny_outlined, 'Spots'),
      (Icons.route,             'Tour'),
      (Icons.favorite_outline,  'Saved'),
    ];
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 12,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: Column(
          children: [
            // Expand/collapse handle
            GestureDetector(
              onTap: () => setState(() => _panelExpanded = !_panelExpanded),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                height: 24,
                child: Center(
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            // Content area
            Expanded(
              child: ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white, Colors.white, Colors.white.withValues(alpha: 0.0)],
                  stops: const [0.0, 0.75, 1.0],
                ).createShader(bounds),
                blendMode: BlendMode.dstIn,
                child: SingleChildScrollView(
                  controller: _mobileContentScroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: _buildMobileTabContent(),
                ),
              ),
            ),
            // Tab bar
            Divider(height: 1, color: Colors.grey.shade200),
            SizedBox(
              height: 56,
              child: Row(
                children: tabs.asMap().entries.map((entry) {
                  final i     = entry.key;
                  final icon  = entry.value.$1;
                  final label = entry.value.$2;
                  final sel   = _mobileTab == i;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        if (i != 1) {
                          setState(() { _sunnySpots = []; _sunnyPois = []; _sunnySpotScreenPos = []; _poiScreenPos = []; });
                          _clearSunnySpots();
                          _clearPoiMarkers();
                          _lastSearchCenter = null;
                          _lastSearchZoom   = null;
                        }
                        setState(() { _mobileTab = i; _panelExpanded = false; _selectedSpot = null; });
                        _mobileContentScroll.jumpTo(0);
                        if (i == 3) _refreshSavedSunny();
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: sel ? Colors.orange.withValues(alpha: 0.12) : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(icon, size: 22,
                                color: sel ? Colors.orange : Colors.grey.shade400),
                          ),
                          const SizedBox(height: 1),
                          Text(label,
                              style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w600,
                                color: sel ? Colors.orange : Colors.grey.shade400,
                              )),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileTabContent() {
    if (_selectedSpot != null) return _buildSpotDetail();
    switch (_mobileTab) {
      case 0: // Time
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTimeHeader(),
            const SizedBox(height: 4),
            _buildTimeSlider(),
            const SizedBox(height: 16),
            _buildDateSection(),
          ],
        );
      case 1: // Spots
        return _buildFindSunnySpotsSection();
      case 2: // Tour
        return _buildTourTab();
      case 3: // Saved
        if (_savedSpots.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.favorite_outline, size: 44, color: Colors.grey.shade300),
                  const SizedBox(height: 10),
                  Text('No saved spots yet',
                      style: TextStyle(fontSize: 14, color: Colors.grey.shade400)),
                  const SizedBox(height: 4),
                  Text('Tap a spot and press Save',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade300)),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.touch_app_outlined, size: 14, color: Colors.grey.shade400),
                      const SizedBox(width: 6),
                      Text('Tap the map to inspect any point',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                    ]),
                  ),
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tap-to-inspect hint
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.touch_app_outlined, size: 13, color: Colors.grey.shade400),
                const SizedBox(width: 6),
                Text('Tap the map to inspect any point',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              ]),
            ),
            ..._savedSpots.asMap().entries.map((e) {
              final idx   = e.key;
              final s     = e.value;
              final lat   = s['lat'] as double;
              final lon   = s['lon'] as double;
              final addr  = s['address'] as String? ?? 'Saved spot ${idx + 1}';
              final sunH  = s['sun_hours_left'] as int? ?? 0;
              final until = s['sun_until'] as int?;
              final key   = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
              final sunny = _savedSunny[key];
              final gps   = _gpsPosition;
              final distLabel = gps != null
                  ? _formatDistance(_distanceMeters(gps, LatLng(lat, lon)))
                  : null;

              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      _showPin(LatLng(lat, lon));
                      _selectSpot(s, idx);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          // Heart circle
                          Container(
                            width: 22, height: 22,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFF8C00),
                              shape: BoxShape.circle,
                            ),
                            child: const Center(
                              child: Icon(Icons.favorite, size: 11, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(addr,
                                    style: const TextStyle(
                                        fontSize: 13, fontWeight: FontWeight.w500),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                Row(children: [
                                  if (distLabel != null) ...[
                                    Icon(Icons.directions_walk, size: 11,
                                        color: Colors.grey.shade500),
                                    const SizedBox(width: 2),
                                    Text(distLabel,
                                        style: TextStyle(fontSize: 11,
                                            color: Colors.grey.shade600)),
                                    const SizedBox(width: 8),
                                  ],
                                  Icon(Icons.wb_sunny_outlined, size: 11,
                                      color: Colors.grey.shade400),
                                  const SizedBox(width: 2),
                                  Text(
                                    until != null
                                        ? '$sunH h · until ${until.toString().padLeft(2, '0')}:00'
                                        : '$sunH h of sun',
                                    style: TextStyle(fontSize: 11,
                                        color: Colors.grey.shade500),
                                  ),
                                  if (sunny != null) ...[
                                    const SizedBox(width: 6),
                                    Icon(
                                      sunny ? Icons.wb_sunny : Icons.nights_stay_outlined,
                                      size: 11,
                                      color: sunny ? Colors.orange.shade500 : Colors.blueGrey.shade300,
                                    ),
                                  ],
                                ]),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _savedSpots.removeAt(idx);
                                _persistSaved();
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(Icons.close, size: 16,
                                  color: Colors.grey.shade400),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

}

// Radial vignette overlay — fades the map edge to mask the rectangular
// shadow boundary. Drawn above MapLibre, below all UI widgets.
class _VignettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // Use the longer axis so the gradient always reaches the corners.
    final radius = sqrt(size.width * size.width + size.height * size.height) / 2;
    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: const [
          Color(0x00F5F0EB), // transparent centre
          Color(0x00F5F0EB), // still transparent at 50%
          Color(0x55F5F0EB), // soft at 75%
          Color(0xCCF5F0EB), // ~80% warm cream at edge
        ],
        stops: const [0.0, 0.50, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Sun direction radar — replaces the "Azimuth 184° NNW" text card.
// Shows a compass circle with the sun icon positioned by azimuth+elevation.
class _SunRadarPainter extends CustomPainter {
  final double azimuth;   // 0=N, 90=E, 180=S, 270=W
  final double elevation; // 0=horizon, 90=zenith

  const _SunRadarPainter({required this.azimuth, required this.elevation});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = min(cx, cy) - 3;

    // Compass circle
    canvas.drawCircle(Offset(cx, cy), r,
        Paint()..color = const Color(0xFFDDDDDD)..style = PaintingStyle.stroke..strokeWidth = 1.0);

    // Cardinal tick marks
    final tickPaint = Paint()..color = const Color(0xFFBBBBBB)..strokeWidth = 1.0;
    for (int i = 0; i < 8; i++) {
      final a = i * pi / 4;
      final inner = r - 4;
      canvas.drawLine(
        Offset(cx + inner * sin(a), cy - inner * cos(a)),
        Offset(cx + r * sin(a),     cy - r * cos(a)),
        tickPaint,
      );
    }

    // N label
    final nPainter = TextPainter(
      text: const TextSpan(text: 'N', style: TextStyle(fontSize: 8, color: Color(0xFF999999), fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    nPainter.paint(canvas, Offset(cx - nPainter.width / 2, cy - r - nPainter.height - 1));

    if (elevation <= 0) {
      // Night — draw moon icon position
      final moonPaint = Paint()..color = const Color(0xFF9E9E9E);
      canvas.drawCircle(Offset(cx, cy), 4, moonPaint);
      return;
    }

    // Sun position: high elevation → near center, horizon → near edge
    final t      = (elevation.clamp(0.0, 90.0) / 90.0);
    final dist   = r * (1.0 - t * 0.75);
    final azRad  = azimuth * pi / 180.0;
    final sx     = cx + dist * sin(azRad);
    final sy     = cy - dist * cos(azRad);

    // Glow
    canvas.drawCircle(Offset(sx, sy), 8,
        Paint()..color = Colors.orange.withValues(alpha: 0.18));
    // Sun dot
    canvas.drawCircle(Offset(sx, sy), 5,
        Paint()..color = Colors.orange.shade400);
    // Bright centre
    canvas.drawCircle(Offset(sx, sy), 2,
        Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SunRadarPainter old) =>
      old.azimuth != azimuth || old.elevation != elevation;
}
